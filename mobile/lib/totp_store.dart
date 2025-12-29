import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TotpRecord {
  TotpRecord({
    required this.issuer,
    required this.account,
    required this.secret,
    required this.userId,
    required this.rpId,
    required this.deviceId,
    required this.apiBaseUrl,
    required this.keyId,
  });

  final String issuer;
  final String account;
  final String secret;
  final String userId;
  final String rpId;
  final String deviceId;
  final String apiBaseUrl;
  final String keyId;

  TotpRecord normalized() {
    return TotpRecord(
      issuer: issuer,
      account: account,
      secret: secret.replaceAll(' ', '').toUpperCase(),
      userId: userId,
      rpId: rpId,
      deviceId: deviceId,
      apiBaseUrl: apiBaseUrl,
      keyId: keyId,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'issuer': issuer,
      'account': account,
      'secret': secret,
      'user_id': userId,
      'rp_id': rpId,
      'device_id': deviceId,
      'api_base_url': apiBaseUrl,
      'key_id': keyId,
    };
  }

  static TotpRecord fromJson(Map<String, dynamic> json) {
    return TotpRecord(
      issuer: json['issuer'] as String? ?? '',
      account: json['account'] as String? ?? '',
      secret: json['secret'] as String? ?? '',
      userId: json['user_id'] as String? ?? '',
      rpId: json['rp_id'] as String? ?? '',
      deviceId: json['device_id'] as String? ?? '',
      apiBaseUrl: json['api_base_url'] as String? ?? '',
      keyId: json['key_id'] as String? ?? '',
    );
  }
}

class TotpStore {
  static const _storage = FlutterSecureStorage();
  static const _prefix = 'totp:';

  Future<List<TotpRecord>> loadAll() async {
    final data = await _storage.readAll();
    final records = <TotpRecord>[];

    for (final entry in data.entries) {
      if (!entry.key.startsWith(_prefix)) {
        continue;
      }
      final value = entry.value;
      if (value == null) {
        continue;
      }
      try {
        final decoded = jsonDecode(value) as Map<String, dynamic>;
        records.add(TotpRecord.fromJson(decoded));
      } catch (_) {
        final parts = entry.key.substring(_prefix.length).split('|');
        if (parts.length != 2) {
          continue;
        }
        records.add(
          TotpRecord(
            issuer: parts[0],
            account: parts[1],
            secret: value,
            userId: '',
            rpId: '',
            deviceId: '',
            apiBaseUrl: '',
            keyId: '',
          ),
        );
      }
    }

    return records;
  }

  Future<void> save(TotpRecord record) async {
    final key = '$_prefix${record.issuer}|${record.account}';
    await _storage.write(key: key, value: jsonEncode(record.normalized().toJson()));
  }

  Future<void> delete(TotpRecord record) async {
    final key = '$_prefix${record.issuer}|${record.account}';
    await _storage.delete(key: key);
  }

  Future<void> clearAll() async {
    final data = await _storage.readAll();
    for (final entry in data.entries) {
      if (entry.key.startsWith(_prefix)) {
        await _storage.delete(key: entry.key);
      }
    }
  }
}
