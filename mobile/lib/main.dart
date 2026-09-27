import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter/services.dart';
import 'app_settings.dart';
import 'device_crypto.dart';
import 'feedback_screen.dart';
import 'help_screen.dart';
import 'how_it_works_screen.dart';
import 'http_client.dart';
import 'poia_intent_view.dart';
import 'qr_scanner_screen.dart';
import 'settings_screen.dart';
import 'totp.dart';
import 'totp_store.dart';
import 'transfer_accounts_screen.dart';
import 'zt_theme.dart';

Map<String, dynamic> validatedPoiaIntent(Map<String, dynamic> data) {
  final raw = data['intent_canonical_json'];
  final proofRaw = data['proof_payload_json'];
  if (raw is! String || proofRaw is! String) {
    throw const FormatException('Missing signed intent bytes');
  }
  final proof = jsonDecode(proofRaw) as Map<String, dynamic>;
  if (sha256.convert(utf8.encode(proofRaw)).toString() != data['intent_hash'] ||
      base64Url.encode(sha256.convert(utf8.encode(raw)).bytes) != proof['intent_hash'] ||
      proof['nonce'] != data['nonce'] || proof['expires_at'] != data['expires_at']) {
    throw const FormatException('Intent digest mismatch');
  }
  return Map<String, dynamic>.from(jsonDecode(raw) as Map);
}

List<List<String>> verifiedDisplayFields(Map<String, dynamic> intent) {
  final fields = <List<String>>[['Action', intent['action'].toString()]];
  for (final section in ['scope', 'context', 'constraints']) {
    final values = intent[section] as Map? ?? {};
    for (final entry in values.entries) {
      if (section == 'constraints' && entry.key == 'expires_in_seconds') {
        // The dialog shows the remaining signed challenge lifetime instead.
        continue;
      }
      if (entry.key == 'referent_commitments') {
        // Not shown on the mobile approval screen: referent-state
        // integrity is enforced server-side (execution is refused if the
        // committed resource's version/hash no longer matches what was
        // signed), so nothing about RSI's guarantee depends on the human
        // re-reading these fields here, and they were pure clutter
        // duplicating the recipient/account fields already shown above.
        continue;
      }
      fields.add([entry.key.toString().replaceAll('_', ' '), entry.value.toString()]);
    }
  }
  return fields;
}

void main() {
  runApp(const ZtAuthenticatorApp());
}

String loginApprovalErrorMessage(Object error) {
  final detail = error.toString().toLowerCase();
  if (detail.contains('no key') ||
      detail.contains('sign_failed') ||
      detail.contains('key permanently invalidated')) {
    return 'This account no longer has its enrolled device signing key. '
        'Remove this account from ZT-Authenticator and enroll it again.';
  }
  return 'The login request could not be signed. Check the connection and '
      'try again.';
}

String loginApprovalResponseMessage(Map<String, dynamic>? response) {
  final reason = response?['reason']?.toString() ?? '';
  switch (reason) {
    case 'expired':
    case 'not_pending':
      return 'This login request expired. Start a new login and try again.';
    case 'invalid_device_proof':
      return 'The device signing key no longer matches this enrollment. '
          'Remove this account from ZT-Authenticator and enroll it again.';
    case 'invalid_otp':
    case 'otp_mismatch':
      return 'The one-time code changed before approval. Start a new login '
          'and sign the fresh request.';
    default:
      return 'The server did not accept the login signature. Start a new '
          'login and try again.';
  }
}

String poiaIntentLabel(String key) {
  const labels = {
    'account': 'Account',
    'amount': 'Amount',
    'currency': 'Currency',
    'duration_hours': 'Duration (hours)',
    'from_account': 'Source account',
    'key_id': 'Key',
    'on_behalf_of': 'Acting on behalf of',
    'patient_id': 'Patient',
    'project': 'Project',
    'purpose': 'Purpose',
    'recipient': 'Recipient',
    'region': 'Region',
    'role': 'Role',
    'rp_id': 'Relying party',
    'target_user': 'Target user',
    'tenant': 'Tenant',
    'to_account': 'Destination account',
    'user_id': 'Authorizing user',
    'workflow_id': 'Workflow',
  };
  final known = labels[key];
  if (known != null) {
    return known;
  }
  final words = key.replaceAll('_', ' ').trim();
  if (words.isEmpty) {
    return key;
  }
  return '${words[0].toUpperCase()}${words.substring(1)}';
}

String poiaIntentValue(dynamic value) {
  if (value == null) {
    return 'Not specified';
  }
  if (value is Map || value is List) {
    return jsonEncode(value);
  }
  return value.toString();
}

// Root app widget: theme + entry screen.
class ZtAuthenticatorApp extends StatelessWidget {
  const ZtAuthenticatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZT-Authenticator',
      theme: ztIamTheme(),
      home: const HomeScreen(),
    );
  }
}

// Landing screen with navigation to research flows.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AppSettings _settings = AppSettings();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _allowInsecureTls = false;
  bool _allowHttpDev = false;
  String _fallbackApiBaseUrl = '';
  Map<String, String> _rpBaseUrls = {};
  final TotpStore _store = TotpStore();
  final List<TotpAccount> _totpAccounts = [];
  Timer? _ticker;
  Timer? _loginPoller;
  final DeviceCrypto _deviceCrypto = DeviceCrypto();
  bool _approvalDialogOpen = false;
  bool _loginPollInFlight = false;
  String _lastLoginId = '';
  bool _poiaDialogOpen = false;
  String _lastPoiaIntentId = '';
  bool _loginPollingEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
    _searchController.addListener(() {
      final next = _searchController.text.trim();
      if (next == _searchQuery) {
        return;
      }
      setState(() {
        _searchQuery = next;
      });
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final storedBaseUrl = await _settings.loadApiBaseUrl();
    final loginPollingEnabled = await _settings.loadLoginPollingEnabled();
    final allowInsecureTls = await _settings.loadAllowInsecureTls();
    final allowHttpDev = await _settings.loadAllowHttpDev();
    final rpBaseUrls = await _settings.loadRpBaseUrls();
    if (!mounted) {
      return;
    }
    setState(() {
      _loginPollingEnabled = loginPollingEnabled;
      _allowInsecureTls = allowInsecureTls;
      _allowHttpDev = allowHttpDev;
      _fallbackApiBaseUrl = storedBaseUrl ?? '';
      _rpBaseUrls = rpBaseUrls;
    });
    _restartLoginPoller();
  }

  void _restartLoginPoller() {
    _loginPoller?.cancel();
    if (!_loginPollingEnabled) {
      _loginPoller = null;
      return;
    }
    _loginPoller = Timer.periodic(const Duration(seconds: 2), (_) {
      _pollLoginApprovals();
      _pollPoiaApprovals();
    });
  }

  Future<void> _loadAccounts() async {
    final records = await _store.loadAll();
    setState(() {
      _totpAccounts
        ..clear()
        ..addAll(records.map(TotpAccount.fromRecord));
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _loginPoller?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _addTotpAccount(TotpAccount account) {
    setState(() {
      _totpAccounts.add(account);
    });
    _loadSettings();
  }

  Future<void> _showAccountInfo() async {
    final accounts = List<TotpAccount>.from(_totpAccounts);
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Accounts'),
          content: SizedBox(
            width: double.maxFinite,
            child: accounts.isEmpty
                ? const Text('No accounts enrolled yet.')
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: accounts.length,
                    separatorBuilder: (_, __) => const Divider(height: 16),
                    itemBuilder: (_, index) {
                      final entry = accounts[index];
                      final issuer = entry.displayIssuer();
                      final account = entry.account.trim();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            issuer,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (account.isNotEmpty)
                            Text(
                              account,
                              style: const TextStyle(color: ZtIamColors.textSecondary),
                            ),
                        ],
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _editAccount(TotpAccount account) async {
    final issuerController = TextEditingController(text: account.issuer);
    final accountController = TextEditingController(text: account.account);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit account'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: issuerController,
                decoration: const InputDecoration(labelText: 'Issuer'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: accountController,
                decoration: const InputDecoration(labelText: 'Email/Account'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final issuer = issuerController.text.trim();
                final accountLabel = accountController.text.trim();
                if (issuer.isEmpty || accountLabel.isEmpty) {
                  return;
                }
                Navigator.of(context).pop({
                  'issuer': issuer,
                  'account': accountLabel,
                });
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (result == null) {
      return;
    }

    final updated = TotpAccount(
      issuer: result['issuer'] ?? account.issuer,
      account: result['account'] ?? account.account,
      secret: account.secret,
      userId: account.userId,
      rpId: account.rpId,
      deviceId: account.deviceId,
      apiBaseUrl: account.apiBaseUrl,
      keyId: account.keyId,
    );
    await _store.delete(account.toRecord());
    await _store.save(updated.toRecord());
    setState(() {
      final idx = _totpAccounts.indexOf(account);
      if (idx >= 0) {
        _totpAccounts[idx] = updated;
      }
    });
  }

  Future<void> _deleteAccount(TotpAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Remove account?'),
          content: Text('Remove ${account.account} from this device?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: ZtIamColors.danger,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    await _store.delete(account.toRecord());
    setState(() {
      _totpAccounts.remove(account);
    });
  }

  String _profileInitial(List<TotpAccount> accounts) {
    if (accounts.isEmpty) {
      return 'P';
    }
    final raw = accounts.first.account.trim();
    if (raw.isEmpty) {
      return 'P';
    }
    final localPart = raw.contains('@') ? raw.split('@').first : raw;
    if (localPart.isEmpty) {
      return 'P';
    }
    return localPart[0].toUpperCase();
  }

  bool _isLocalHost(String host) {
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        RegExp(r'^[0-9.]+$').hasMatch(host) ||
        host.endsWith('.local') ||
        host.endsWith('.localdomain.com');
  }

  bool _looksLikeHost(String host) {
    return host.contains('.') ||
        host == 'localhost' ||
        RegExp(r'^[0-9.]+$').hasMatch(host);
  }

  bool _sameRpFamily(String left, String right) {
    final a = left.trim().toLowerCase();
    final b = right.trim().toLowerCase();
    if (a == b) {
      return true;
    }
    const aliases = {'zt-iam.com', 'ztiam.com', 'zt-aim.com'};
    return aliases.contains(a) && aliases.contains(b);
  }

  String _coerceBaseUrl(String raw) {
    final trimmed = raw.trim();
    final uri = Uri.tryParse(trimmed);
    if (trimmed.isEmpty || uri == null) {
      return trimmed;
    }
    return trimmed;
  }

  String _resolveAccountBaseUrl(TotpAccount account) {
    final rpId = account.rpId.trim();
    final mapped = _rpBaseUrls[rpId]?.trim() ?? '';
    if (mapped.isNotEmpty) {
      return _coerceBaseUrl(mapped);
    }
    if (account.apiBaseUrl.trim().isNotEmpty) {
      return _coerceBaseUrl(account.apiBaseUrl.trim());
    }
    if (rpId.isNotEmpty && _looksLikeHost(rpId)) {
      final scheme = _allowHttpDev && _isLocalHost(rpId) ? 'http' : 'https';
      return '$scheme://$rpId/api/auth';
    }
    if (_fallbackApiBaseUrl.trim().isNotEmpty) {
      return _coerceBaseUrl(_fallbackApiBaseUrl);
    }
    return '';
  }

  String _resolveFeedbackBaseUrl() {
    if (_fallbackApiBaseUrl.trim().isNotEmpty) {
      return _coerceBaseUrl(_fallbackApiBaseUrl);
    }
    return _totpAccounts
        .map(_resolveAccountBaseUrl)
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
  }

  Future<Map<String, String>> _pollHeaders(TotpAccount account, String path) async {
    final random = math.Random.secure();
    final nonce = List.generate(24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final stamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final signature = await _deviceCrypto.sign(
      rpId: account.rpId, deviceId: account.deviceId, nonce: nonce,
      otp: 'poll-v1:$path:${account.userId}:$stamp',
      keyId: account.keyId.isEmpty ? account.rpId : account.keyId,
    );
    return {'X-PoIA-Poll-Nonce': nonce, 'X-PoIA-Poll-Time': stamp, 'X-PoIA-Poll-Signature': signature};
  }

  Future<Map<String, dynamic>?> _accountGet(
    TotpAccount account,
    String path,
  ) async {
    final baseUrl = _resolveAccountBaseUrl(account);
    if (baseUrl.isEmpty) {
      return null;
    }
    final client =
        ApiClient(baseUrl: baseUrl, allowInsecureTls: _allowInsecureTls);
    try {
      final headers = path.startsWith('/login/pending?')
          ? await _pollHeaders(account, '/api/auth/login/pending') : null;
      final response = await client.get(path, headers: headers).timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        return null;
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      // One unreachable account must not abort pending requests for others.
      return null;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>?> _accountPost(
    TotpAccount account,
    String path,
    Map<String, dynamic> payload,
  ) async {
    final baseUrl = _resolveAccountBaseUrl(account);
    if (baseUrl.isEmpty) {
      return null;
    }
    final client =
        ApiClient(baseUrl: baseUrl, allowInsecureTls: _allowInsecureTls);
    try {
      final response = await client.postJson(path, payload);
      Map<String, dynamic>? body;
      try {
        body = jsonDecode(response.body) as Map<String, dynamic>;
      } on FormatException {
        body = null;
      }
      if (response.statusCode != 200) {
        return body ?? {'reason': 'http_${response.statusCode}'};
      }
      return body;
    } finally {
      client.close();
    }
  }

  Future<void> _pollLoginApprovals() async {
    if (_totpAccounts.isEmpty || _loginPollInFlight) {
      return;
    }
    _loginPollInFlight = true;
    try {
      final candidates = _totpAccounts
          .where((account) =>
              account.userId.isNotEmpty &&
              account.rpId.isNotEmpty &&
              account.deviceId.isNotEmpty)
          .toList(growable: false);
      if (candidates.isEmpty) {
        return;
      }
      final futures = candidates
          .map(
            (account) => _accountGet(
              account,
              '/login/pending?${Uri(queryParameters: {
                    'user_id': account.userId,
                    'device_id': account.deviceId,
                    'rp_id': account.rpId,
                  }).query}',
            ),
          )
          .toList(growable: false);
      final results = await Future.wait(futures);
      for (var i = 0; i < candidates.length; i++) {
        final account = candidates[i];
        final data = results[i];
        if (data == null || data['status'] != 'pending') {
          continue;
        }
        final pendingRp = data['rp_id'] as String? ?? '';
        final pendingDevice = data['device_id'] as String? ?? '';
        final loginId = data['login_id'] as String? ?? '';
        final nonce = data['nonce'] as String? ?? '';
        if (!_sameRpFamily(pendingRp, account.rpId) ||
            pendingDevice != account.deviceId ||
            loginId.isEmpty ||
            nonce.isEmpty) {
          continue;
        }
        if (_approvalDialogOpen || _poiaDialogOpen || loginId == _lastLoginId) {
          continue;
        }
        _lastLoginId = loginId;
        if (!mounted) {
          return;
        }
        _approvalDialogOpen = true;
        try {
          final completed = await _showApprovalDialog(
            account: account,
            loginId: loginId,
            nonce: nonce,
            pendingRp: pendingRp,
            pendingDevice: pendingDevice,
          );
          if (!completed) {
            _lastLoginId = '';
          }
        } catch (_) {
          _lastLoginId = '';
        } finally {
          // Always release the flag, even if the dialog failed to show or
          // throw mid-flow -- otherwise every later login request is
          // silently skipped for the rest of the app session.
          _approvalDialogOpen = false;
        }
        return;
      }
    } finally {
      _loginPollInFlight = false;
    }
  }

  Future<bool> _showApprovalDialog({
    required TotpAccount account,
    required String loginId,
    required String nonce,
    required String pendingRp,
    required String pendingDevice,
  }) async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) {
            var submitting = false;
            String? status;
            return StatefulBuilder(builder: (context, setDialogState) {
              Future<void> sendDecision(bool approve) async {
                setDialogState(() {
                  submitting = true;
                  status = approve
                      ? 'Signing login request...'
                      : 'Signing denial...';
                });
                try {
                  final otp =
                      approve ? account.currentCode() : 'login-deny:$loginId';
                  final signature = await _deviceCrypto.sign(
                    rpId: pendingRp,
                    nonce: nonce,
                    deviceId: pendingDevice,
                    otp: otp,
                    keyId: account.keyId.isEmpty ? account.rpId : account.keyId,
                  );
                  if (signature.isEmpty) {
                    throw StateError('Device returned an empty signature.');
                  }
                  final response = await _accountPost(
                    account,
                    approve ? '/login/approve' : '/login/deny',
                    {
                      'login_id': loginId,
                      'device_id': pendingDevice,
                      'rp_id': pendingRp,
                      if (approve) 'otp': otp,
                      'nonce': nonce,
                      'signature': signature,
                      if (!approve) 'reason': 'user_denied',
                    },
                  );
                  final responseStatus = response?['status'];
                  final accepted = approve
                      ? responseStatus == 'ok'
                      : responseStatus == 'denied';
                  if (accepted && context.mounted) {
                    Navigator.of(context).pop(true);
                    return;
                  }
                  if (context.mounted) {
                    setDialogState(() {
                      status = loginApprovalResponseMessage(response);
                    });
                  }
                } catch (error) {
                  if (context.mounted) {
                    setDialogState(() {
                      status = loginApprovalErrorMessage(error);
                    });
                  }
                } finally {
                  if (context.mounted) {
                    setDialogState(() {
                      submitting = false;
                    });
                  }
                }
              }

              return AlertDialog(
                title: const Text('Sign login request?'),
                scrollable: true,
                insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Same visual language as the PoIA intent dialog: a
                    // simple person avatar for who is signing in, larger
                    // identity text, and a muted relying-party line.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor:
                              ZtIamColors.accentBlue.withValues(alpha: 0.22),
                          child: const Icon(Icons.person,
                              color: ZtIamColors.accentBlue, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Signing in as',
                                  style: TextStyle(
                                      color: ZtIamColors.textSecondary, fontSize: 12)),
                              const SizedBox(height: 2),
                              Text(
                                account.displayAccount(),
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: ZtIamColors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.verified_user_outlined,
                            size: 18, color: ZtIamColors.accentSoft),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Relying party: $pendingRp',
                            style: const TextStyle(
                                fontSize: 15, color: ZtIamColors.textSecondary),
                          ),
                        ),
                      ],
                    ),
                    if (status != null) ...[
                      const SizedBox(height: 14),
                      Text(status!,
                          key: const Key('login-approval-status'),
                          style: const TextStyle(color: ZtIamColors.textSecondary)),
                    ],
                    const SizedBox(height: 14),
                    const Divider(color: ZtIamColors.divider, height: 1),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: submitting
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('Close'),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ZtIamColors.danger,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: submitting ? null : () => sendDecision(false),
                    child: const Text('Deny'),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ZtIamColors.accentGreen,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: submitting ? null : () => sendDecision(true),
                    child: const Text('Sign'),
                  ),
                ],
              );
            });
          },
        ) ??
        false;
  }

  String _resolvePoiaBaseUrl(TotpAccount account) {
    final authBase = _resolveAccountBaseUrl(account);
    final uri = Uri.tryParse(authBase);
    if (uri == null) {
      return '';
    }
    return '${uri.scheme}://${uri.authority}';
  }

  bool _poiaPollInFlight = false;

  Future<void> _pollPoiaApprovals() async {
    if (_poiaPollInFlight || !mounted) return;
    _poiaPollInFlight = true;
    try {
      await _pollPoiaApprovalAccounts();
    } finally {
      _poiaPollInFlight = false;
    }
  }

  Future<void> _pollPoiaApprovalAccounts() async {
    if (_totpAccounts.isEmpty) {
      return;
    }
    final accounts = List<TotpAccount>.of(_totpAccounts);
    final pending = await Future.wait(accounts.map(_pendingPoiaForAccount));
    for (var index = 0; index < accounts.length; index++) {
      final account = accounts[index];
      if (!mounted) return;
      if (account.userId.isEmpty ||
          account.deviceId.isEmpty ||
          account.rpId.isEmpty) {
        continue;
      }
      final baseUrl = _resolvePoiaBaseUrl(account);
      if (baseUrl.isEmpty) {
        continue;
      }
      try {
        final data = pending[index];
        if (data == null) continue;
        if (data['status'] != 'pending') {
          continue;
        }
        final intentId = data['intent_id']?.toString() ?? '';
        final nonce = data['nonce']?.toString() ?? '';
        final proofHash = data['intent_hash']?.toString() ?? '';
        final rpId = (data['rp_id'] as String?)?.trim() ?? account.rpId;
        final intentRaw = validatedPoiaIntent(data);
        if (intentId.isEmpty ||
            nonce.isEmpty ||
            proofHash.isEmpty) {
          continue;
        }
        if (rpId.isNotEmpty && rpId != account.rpId) {
          continue;
        }
        if (_poiaDialogOpen || _approvalDialogOpen || intentId == _lastPoiaIntentId) {
          continue;
        }
        _lastPoiaIntentId = intentId;
        if (!mounted) {
          return;
        }
        _poiaDialogOpen = true;
        try {
          await _showPoiaApprovalDialog(
            account: account,
            intentId: intentId,
            intent: Map<String, dynamic>.from(intentRaw),
            nonce: nonce,
            proofHash: proofHash,
            rpId: rpId,
            baseUrl: baseUrl,
            expiresAt: (data['expires_at'] as num).toInt(),
            displayFields: verifiedDisplayFields(intentRaw),
            // Presentation-only metadata alongside the verified intent (a
            // sibling of intent/display_fields/signing_backend in the
            // /api/poia/pending response), never part of the signed payload
            // -- purely selects the study display arm. Defaults to
            // 'redesigned' for every real (non-study) user and any older
            // response that doesn't send this field.
            displayVariant: data['display_variant'] as String? ?? 'redesigned',
          );
        } finally {
          // Always release the flag, even if the dialog failed to show or
          // throw mid-flow -- otherwise every later intent-signing request
          // is silently skipped for the rest of the app session.
          _poiaDialogOpen = false;
        }
      } catch (_) {
        _lastPoiaIntentId = '';
        continue;
      }
    }
  }

  Future<Map<String, dynamic>?> _pendingPoiaForAccount(TotpAccount account) async {
    if (account.userId.isEmpty || account.deviceId.isEmpty || account.rpId.isEmpty) {
      return null;
    }
    final baseUrl = _resolvePoiaBaseUrl(account);
    if (baseUrl.isEmpty) return null;
    final client = ApiClient(baseUrl: baseUrl, allowInsecureTls: _allowInsecureTls);
    try {
      final query = Uri(queryParameters: {
        'user_id': account.userId,
        'device_id': account.deviceId,
        'rp_id': account.rpId,
      }).query;
      final headers = await _pollHeaders(account, '/api/poia/pending');
      final response = await client.get('/api/poia/pending?$query', headers: headers)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return null;
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  Future<void> _showPoiaApprovalDialog({
    required TotpAccount account,
    required String intentId,
    required Map<String, dynamic> intent,
    required String nonce,
    required String proofHash,
    required String rpId,
    required String baseUrl,
    required int expiresAt,
    List<dynamic> displayFields = const [],
    String displayVariant = 'redesigned',
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        var submitting = false;
        var status = '';
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> sendDecision(bool approve) async {
              setDialogState(() {
                submitting = true;
                status = approve ? 'Signing intent...' : 'Sending denial...';
              });
              final client = ApiClient(
                  baseUrl: baseUrl, allowInsecureTls: _allowInsecureTls);
              try {
                if (approve) {
                  final signature = await _deviceCrypto.sign(
                    rpId: rpId,
                    nonce: nonce,
                    deviceId: account.deviceId,
                    otp: 'poia-approve:$proofHash',
                    keyId: account.keyId.isEmpty ? account.rpId : account.keyId,
                  );
                  final response = await client.postJson('/api/poia/approve', {
                    'intent_id': intentId,
                    'device_id': account.deviceId,
                    'rp_id': rpId,
                    'nonce': nonce,
                    'signature': signature,
                    'intent_hash': proofHash,
                  });
                  if (response.statusCode == 200) {
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                    return;
                  }
                  final body = response.body.trim();
                  String message = 'Intent signing failed.';
                  if (body.isNotEmpty) {
                    try {
                      final decoded = jsonDecode(body);
                      if (decoded is Map && decoded['reason'] != null) {
                        message = 'Intent signing failed: ${decoded['reason']}';
                      } else {
                        message = 'Intent signing failed: $body';
                      }
                    } catch (_) {
                      message = 'Intent signing failed: $body';
                    }
                  }
                  setDialogState(() {
                    status = message;
                  });
                } else {
                  final signature = await _deviceCrypto.sign(
                    rpId: rpId,
                    nonce: nonce,
                    deviceId: account.deviceId,
                    otp: 'poia-deny:$proofHash',
                    keyId: account.keyId.isEmpty ? account.rpId : account.keyId,
                  );
                  final response = await client.postJson('/api/poia/deny', {
                    'intent_id': intentId,
                    'device_id': account.deviceId,
                    'rp_id': rpId,
                    'nonce': nonce,
                    'signature': signature,
                    'intent_hash': proofHash,
                    'reason': 'user_denied',
                  });
                  if (response.statusCode == 200) {
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                    return;
                  }
                  final body = response.body.trim();
                  String message = 'Denial failed.';
                  if (body.isNotEmpty) {
                    try {
                      final decoded = jsonDecode(body);
                      if (decoded is Map && decoded['reason'] != null) {
                        message = 'Denial failed: ${decoded['reason']}';
                      } else {
                        message = 'Denial failed: $body';
                      }
                    } catch (_) {
                      message = 'Denial failed: $body';
                    }
                  }
                  setDialogState(() {
                    status = message;
                  });
                }
              } catch (error) {
                if (context.mounted) {
                  setDialogState(() { status = 'Error: $error'; });
                }
              } finally {
                client.close();
                if (context.mounted) {
                  setDialogState(() { submitting = false; });
                }
              }
            }

            final action =
                (intent['action'] as String?)?.trim() ?? 'Sign intent';
            final scope = intent['scope'] as Map<String, dynamic>? ?? {};
            final contextData =
                intent['context'] as Map<String, dynamic>? ?? {};
            final visibleContext = contextData.entries
                .where((entry) => entry.key != 'rp_id')
                .toList(growable: false);
            final resolvedFields = displayFields
                .whereType<List<dynamic>>()
                .where((pair) => pair.length == 2)
                .map((pair) => MapEntry(pair[0].toString(), pair[1].toString()))
                .toList(growable: false);
            return AlertDialog(
              title: const Text('Sign intent'),
              insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (resolvedFields.isNotEmpty) ...[
                        // Every value below comes straight from
                        // verifiedDisplayFields(intentRaw) (see the call
                        // site above and its definition near the top of
                        // this file), which is itself derived only from the
                        // hash-verified intent object. PoiaIntentSummary is
                        // purely a re-layout of that same data -- it never
                        // fetches or substitutes a different value.
                        PoiaIntentSummary(
                          displayFields: resolvedFields,
                          youLabel: account.displayAccount().trim().isEmpty
                              ? 'You'
                              : account.displayAccount().trim(),
                          displayVariant: displayVariant,
                        ),
                      ] else ...[
                        const Text('Action',
                            style:
                                TextStyle(color: ZtIamColors.textSecondary, fontSize: 12)),
                        Text(poiaIntentLabel(action),
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 12),
                        if (scope.isNotEmpty) ...[
                          const Text('Scope',
                              style: TextStyle(
                                  color: ZtIamColors.textSecondary, fontSize: 12)),
                          const SizedBox(height: 4),
                          ...scope.entries.map(
                            (entry) => Text(
                              '${poiaIntentLabel(entry.key)}: ${poiaIntentValue(entry.value)}',
                              style: const TextStyle(color: ZtIamColors.textSecondary),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        const Text('Authorization context',
                            style: TextStyle(
                                color: ZtIamColors.textSecondary, fontSize: 12)),
                        const SizedBox(height: 4),
                        Text('Relying party: $rpId',
                            style: const TextStyle(color: ZtIamColors.textSecondary)),
                        ...visibleContext.map(
                          (entry) => Text(
                            '${poiaIntentLabel(entry.key)}: ${poiaIntentValue(entry.value)}',
                            style: const TextStyle(color: ZtIamColors.textSecondary),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      PoiaExpiryCountdown(expiresAt: expiresAt),
                      if (status.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(status,
                            style: const TextStyle(color: ZtIamColors.textSecondary)),
                      ],
                      // Keeps the signing/authorization action visually
                      // separate from the transaction details above it.
                      const SizedBox(height: 16),
                      const Divider(color: ZtIamColors.divider, height: 1),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: ZtIamColors.danger,
                  ),
                  onPressed: submitting ? null : () => sendDecision(false),
                  child: const Text('Deny'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ZtIamColors.accentGreen,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: submitting ? null : () => sendDecision(true),
                  child: const Text('Sign intent'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _openActions() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ZtIamColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              const _BottomSheetHandle(),
              const SizedBox(height: 12),
              _SheetAction(
                icon: Icons.qr_code,
                label: 'TOTP setup (QR)',
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TotpSetupScreen(
                        fallbackBaseUrl: _fallbackApiBaseUrl,
                        onBaseUrlDetected: (baseUrl) {
                          if (baseUrl.isEmpty) {
                            return;
                          }
                          _settings.saveApiBaseUrl(baseUrl);
                          setState(() {
                            _fallbackApiBaseUrl = baseUrl;
                          });
                        },
                        onRegistered: _addTotpAccount,
                      ),
                    ),
                  );
                },
              ),
              _SheetAction(
                icon: Icons.approval_outlined,
                label: 'Login approvals',
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LoginApprovalsScreen(
                        accounts: List<TotpAccount>.from(_totpAccounts),
                        deviceCrypto: _deviceCrypto,
                        allowInsecureTls: _allowInsecureTls,
                        fallbackBaseUrl: _fallbackApiBaseUrl,
                        allowHttpDev: _allowHttpDev,
                        rpBaseUrls: _rpBaseUrls,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final accounts = List<TotpAccount>.from(_totpAccounts);
    final filteredAccounts = _filterAccounts(accounts);
    final profileInitial = _profileInitial(accounts);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ZT-Authenticator'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: InkWell(
              onTap: _showAccountInfo,
              borderRadius: BorderRadius.circular(20),
              child: CircleAvatar(
                backgroundColor: ZtIamColors.accentBlue,
                foregroundColor: Colors.white,
                child: Text(profileInitial),
              ),
            ),
          ),
        ],
      ),
      drawer: _AppDrawer(
        onTransferAccounts: () async {
          final changed = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => TransferAccountsScreen(store: _store),
            ),
          );
          if (changed == true) {
            await _loadAccounts();
          }
        },
        onHowItWorks: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const HowItWorksScreen()),
          );
        },
        onSettings: () async {
          final result = await Navigator.of(context).push<SettingsResult>(
            MaterialPageRoute(
              builder: (_) => SettingsScreen(
                initialLoginPolling: _loginPollingEnabled,
                initialAllowInsecureTls: _allowInsecureTls,
                initialAllowHttpDev: _allowHttpDev,
                settings: _settings,
              ),
            ),
          );
          if (result == null) {
            return;
          }
          setState(() {
            _loginPollingEnabled = result.loginPolling;
            _allowInsecureTls = result.allowInsecureTls;
            _allowHttpDev = result.allowHttpDev;
          });
          _restartLoginPoller();
        },
        onSendFeedback: () {
          final baseUrl = _resolveFeedbackBaseUrl();
          if (baseUrl.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('No server available for feedback.')),
            );
            return;
          }
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => FeedbackScreen(
                apiClient: ApiClient(
                  baseUrl: baseUrl,
                  allowInsecureTls: _allowInsecureTls,
                ),
              ),
            ),
          );
        },
        onHelp: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const HelpScreen()),
          );
        },
      ),
      body: Container(
        decoration:
            const BoxDecoration(gradient: ZtIamColors.backgroundGradient),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                        },
                      ),
              ),
            ),
            const SizedBox(height: 16),
            if (accounts.isEmpty)
              const _EmptyState()
            else if (filteredAccounts.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'No matching accounts found.',
                    style: TextStyle(color: ZtIamColors.textSecondary),
                  ),
                ),
              )
            else
              ...filteredAccounts.map(
                (entry) => _AccountRow(
                  entry: entry,
                  onEdit: () => _editAccount(entry),
                  onDelete: () => _deleteAccount(entry),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openActions,
        child: const Icon(Icons.add),
      ),
    );
  }

  List<TotpAccount> _filterAccounts(List<TotpAccount> accounts) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return accounts;
    }
    return accounts.where((entry) {
      final issuer = entry.displayIssuer().toLowerCase();
      final account = entry.account.toLowerCase();
      final rpId = entry.rpId.toLowerCase();
      return issuer.contains(query) ||
          account.contains(query) ||
          rpId.contains(query);
    }).toList();
  }
}

class TotpAccount {
  TotpAccount({
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

  String displayAccount() {
    final value = account.trim();
    for (final prefix in [issuer.trim(), displayIssuer(), rpId.trim()]) {
      if (prefix.isNotEmpty && value.toLowerCase().startsWith('${prefix.toLowerCase()}:')) {
        return value.substring(prefix.length + 1).trim();
      }
    }
    return value;
  }

  String displayIssuer() {
    final issuerValue = issuer.trim();
    if (issuerValue.isEmpty) {
      return _shortenDomain(rpId);
    }
    final cleanedIssuer = _normalizeIssuer(issuerValue);
    final detectedDomain = _extractDomain(cleanedIssuer);
    if (detectedDomain.isNotEmpty) {
      return detectedDomain;
    }
    if (cleanedIssuer.contains('@')) {
      final domain = cleanedIssuer.split('@').last.trim();
      return _shortenDomain(domain);
    }
    return _shortenDomain(cleanedIssuer);
  }

  String _normalizeIssuer(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    final dotParts = trimmed.split('.');
    if (dotParts.length == 2 &&
        dotParts[0].toLowerCase() == dotParts[1].toLowerCase()) {
      return dotParts[0];
    }
    final colonParts = trimmed.split(':');
    if (colonParts.length == 2 &&
        colonParts[0].toLowerCase() == colonParts[1].toLowerCase()) {
      return colonParts[0];
    }
    return trimmed;
  }

  String _extractDomain(String value) {
    final match = RegExp(r'([A-Za-z0-9-]+\.)+[A-Za-z]{2,}').firstMatch(value);
    if (match == null) {
      return '';
    }
    return _shortenDomain(match.group(0) ?? '');
  }

  String _shortenDomain(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return 'Unknown issuer';
    }
    final cleaned = trimmed.replaceFirst(RegExp(r'^https?://'), '');
    return cleaned.split('/').first;
  }

  String currentCode() {
    return generateTotp(secret.replaceAll(' ', '').toUpperCase());
  }

  int secondsRemaining() {
    final seconds = DateTime.now().second % 30;
    return 30 - seconds;
  }

  double progress() {
    final elapsed = DateTime.now().second % 30;
    return elapsed / 30.0;
  }

  factory TotpAccount.fromRecord(TotpRecord record) {
    return TotpAccount(
      issuer: record.issuer,
      account: record.account,
      secret: record.secret,
      userId: record.userId,
      rpId: record.rpId,
      deviceId: record.deviceId,
      apiBaseUrl: record.apiBaseUrl,
      keyId: record.keyId,
    );
  }

  TotpRecord toRecord() {
    return TotpRecord(
      issuer: issuer,
      account: account,
      secret: secret,
      userId: userId,
      rpId: rpId,
      deviceId: deviceId,
      apiBaseUrl: apiBaseUrl,
      keyId: keyId,
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.entry,
    required this.onEdit,
    required this.onDelete,
  });

  final TotpAccount entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Slidable(
      key: ValueKey('${entry.issuer}|${entry.account}|${entry.deviceId}'),
      startActionPane: ActionPane(
        motion: const StretchMotion(),
        children: [
          SlidableAction(
            onPressed: (_) => onEdit(),
            backgroundColor: ZtIamColors.accentBlueDark,
            foregroundColor: Colors.white,
            icon: Icons.edit,
          ),
          SlidableAction(
            onPressed: (_) => onDelete(),
            backgroundColor: ZtIamColors.danger,
            foregroundColor: Colors.white,
            icon: Icons.delete,
          ),
        ],
      ),
      child: _AccountTile(entry: entry),
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({required this.entry});

  final TotpAccount entry;

  @override
  Widget build(BuildContext context) {
    final code = entry.currentCode();
    final progress = entry.progress();
    final issuer = entry.displayIssuer();
    final account = entry.displayAccount();

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: issuer, style: const TextStyle(fontWeight: FontWeight.w700)),
                      if (account.isNotEmpty)
                        TextSpan(text: ' · $account', style: const TextStyle(fontWeight: FontWeight.w500)),
                    ]),
                    maxLines: 1,
                    softWrap: false,
                    style: const TextStyle(fontSize: 17, color: ZtIamColors.textPrimary),
                  ),
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onLongPress: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('TOTP code copied')),
                      );
                    }
                  },
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _formatCode(code),
                      style: const TextStyle(
                        fontSize: 34,
                        letterSpacing: 1.6,
                        color: ZtIamColors.accentSoft,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                const Divider(color: ZtIamColors.divider),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _ProgressRing(progress: progress),
        ],
      ),
    );
  }
}

class _ProgressRing extends StatelessWidget {
  const _ProgressRing({
    required this.progress,
  });

  final double progress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 46,
      height: 46,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ShaderMask(
            shaderCallback: (rect) {
              return const SweepGradient(
                startAngle: -math.pi / 2,
                endAngle: math.pi * 1.5,
                colors: [
                  ZtIamColors.accentBlue,
                  ZtIamColors.accentSoftMuted,
                ],
              ).createShader(rect);
            },
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 4,
              backgroundColor: ZtIamColors.divider,
              valueColor: const AlwaysStoppedAnimation<Color>(ZtIamColors.accentGreen),
              strokeCap: StrokeCap.round,
            ),
          ),
          const SizedBox.shrink(),
        ],
      ),
    );
  }
}

String _formatCode(String code) {
  if (code.length <= 3) {
    return code;
  }
  return '${code.substring(0, 3)} ${code.substring(3)}';
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(Icons.lock_outline, size: 48, color: ZtIamColors.textMuted),
          SizedBox(height: 12),
          Text(
            'No accounts yet',
            style: TextStyle(color: ZtIamColors.textSecondary, fontSize: 16),
          ),
          SizedBox(height: 4),
          Text(
            'Add an account using TOTP setup.',
            style: TextStyle(color: ZtIamColors.textMuted),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _AppDrawer extends StatelessWidget {
  const _AppDrawer({
    required this.onTransferAccounts,
    required this.onHowItWorks,
    required this.onSettings,
    required this.onSendFeedback,
    required this.onHelp,
  });

  final VoidCallback onTransferAccounts;
  final VoidCallback onHowItWorks;
  final VoidCallback onSettings;
  final VoidCallback onSendFeedback;
  final VoidCallback onHelp;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: ZtIamColors.surface,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'ZT-Authenticator',
              style: TextStyle(fontSize: 20, color: ZtIamColors.textPrimary),
            ),
            const SizedBox(height: 24),
            _DrawerItem(
              icon: Icons.sync_alt,
              label: 'Transfer accounts',
              onTap: onTransferAccounts,
            ),
            _DrawerItem(
              icon: Icons.info_outline,
              label: 'How it works',
              onTap: onHowItWorks,
            ),
            const Divider(color: ZtIamColors.divider),
            _DrawerItem(
              icon: Icons.settings,
              label: 'Settings',
              onTap: onSettings,
            ),
            _DrawerItem(
              icon: Icons.feedback_outlined,
              label: 'Send feedback',
              onTap: onSendFeedback,
            ),
            _DrawerItem(
              icon: Icons.help_outline,
              label: 'Help',
              onTap: onHelp,
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({
    required this.icon,
    required this.label,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: ZtIamColors.textSecondary),
      title: Text(label, style: const TextStyle(color: ZtIamColors.textSecondary)),
      onTap: () {
        Navigator.of(context).pop();
        onTap?.call();
      },
    );
  }
}

class _BottomSheetHandle extends StatelessWidget {
  const _BottomSheetHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 4,
      decoration: BoxDecoration(
        color: ZtIamColors.divider,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: ZtIamColors.textSecondary),
      title: Text(label, style: const TextStyle(color: ZtIamColors.textPrimary)),
      onTap: onTap,
    );
  }
}

// TOTP registration: calls backend to generate secret + QR.
class TotpSetupScreen extends StatefulWidget {
  const TotpSetupScreen({
    super.key,
    required this.fallbackBaseUrl,
    this.onBaseUrlDetected,
    required this.onRegistered,
  });

  final String fallbackBaseUrl;
  final ValueChanged<String>? onBaseUrlDetected;
  final ValueChanged<TotpAccount> onRegistered;

  @override
  State<TotpSetupScreen> createState() => _TotpSetupScreenState();
}

class _TotpSetupScreenState extends State<TotpSetupScreen> {
  final TotpStore _store = TotpStore();
  final DeviceCrypto _deviceCrypto = DeviceCrypto();
  final AppSettings _settings = AppSettings();
  final TextEditingController _setupKeyController = TextEditingController();
  String _status = '';
  List<String> _recoveryCodes = [];
  bool _loading = false;
  Map<String, dynamic>? _pendingPayload;
  String _detectedBaseUrl = '';
  String _connectivityHint = '';
  bool _allowInsecureTls = false;
  bool _allowHttpDev = false;
  Map<String, String> _rpBaseUrls = {};
  String _lastEmail = '';
  String _lastRpId = '';
  String _lastIssuer = '';
  String _lastAccount = '';
  String _lastUserId = '';
  String _lastDeviceId = '';

  @override
  void dispose() {
    _setupKeyController.dispose();
    super.dispose();
  }

  Future<void> _scanQr() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (result == null || result.isEmpty) {
      return;
    }

    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(result) as Map<String, dynamic>;
    } catch (_) {
      setState(() {
        _status = 'Scanned QR is not a valid enrollment payload.';
      });
      return;
    }

    if (payload['type'] != 'zt_totp_enroll') {
      setState(() {
        _status = 'Enrollment QR type not recognized.';
      });
      return;
    }

    await _startEnrollment(_prepareEnrollmentPayload(payload));
  }

  @override
  void initState() {
    super.initState();
    _loadPendingEnrollment();
    _loadNetworkSettings();
  }

  Future<void> _loadPendingEnrollment() async {
    final raw = await _settings.loadPendingEnrollment();
    if (raw == null || raw.isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (_enrollmentExpiresAt(decoded) == null ||
          _isEnrollmentExpired(decoded)) {
        await _settings.clearPendingEnrollment();
        if (mounted) {
          setState(() {
            _pendingPayload = null;
            _status = 'Previous enrollment expired. Scan a new QR code.';
          });
        }
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _pendingPayload = decoded;
      });
    } catch (_) {
      await _settings.clearPendingEnrollment();
    }
  }

  Map<String, dynamic> _prepareEnrollmentPayload(
    Map<String, dynamic> payload,
  ) {
    final prepared = Map<String, dynamic>.from(payload);
    if (_enrollmentExpiresAt(prepared) == null) {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      prepared['_client_issued_at'] = now;
      prepared['_client_expires_at'] = now + 600;
    }
    return prepared;
  }

  int? _enrollmentExpiresAt(Map<String, dynamic> payload) {
    final raw = payload['expires_at'] ?? payload['_client_expires_at'];
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse(raw?.toString() ?? '');
  }

  bool _isEnrollmentExpired(Map<String, dynamic> payload) {
    final expiresAt = _enrollmentExpiresAt(payload);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return expiresAt == null || now >= expiresAt;
  }

  Future<void> _loadNetworkSettings() async {
    final allowInsecureTls = await _settings.loadAllowInsecureTls();
    final allowHttpDev = await _settings.loadAllowHttpDev();
    final rpBaseUrls = await _settings.loadRpBaseUrls();
    if (!mounted) {
      return;
    }
    setState(() {
      _allowInsecureTls = allowInsecureTls;
      _allowHttpDev = allowHttpDev;
      _rpBaseUrls = rpBaseUrls;
    });
  }

  String _coerceBaseUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return _normalizeBaseUrl(trimmed);
    }
    return _normalizeBaseUrl('${_defaultScheme(trimmed)}://$trimmed');
  }

  String _resolveApiBaseUrl(Map<String, dynamic> payload) {
    final candidates = _resolveApiBaseUrls(payload);
    if (candidates.isNotEmpty) {
      return candidates.first;
    }
    return '';
  }

  List<String> _resolveApiBaseUrls(Map<String, dynamic> payload) {
    final candidates = <String>[];
    void addCandidate(String? raw) {
      final value = raw?.trim() ?? '';
      if (value.isEmpty) {
        return;
      }
      final cleaned = _stripWhitespace(value);
      final normalized =
          cleaned.startsWith('http://') || cleaned.startsWith('https://')
              ? _normalizeBaseUrl(cleaned)
              : _normalizeBaseUrl('${_defaultScheme(cleaned)}://$cleaned');
      if (normalized.isNotEmpty && !candidates.contains(normalized)) {
        candidates.add(normalized);
      }
    }

    final rawBase = (payload['api_base_url'] as String?)?.trim() ??
        (payload['base_url'] as String?)?.trim() ??
        (payload['enroll_url'] as String?)?.trim() ??
        '';
    if (rawBase.isNotEmpty) {
      addCandidate(rawBase);
    }

    final rawCandidates = payload['api_base_urls'];
    if (rawCandidates is List) {
      for (final candidate in rawCandidates) {
        addCandidate(candidate?.toString());
      }
    }

    final rpId = (payload['rp_id'] as String?)?.trim() ?? '';
    if (candidates.isEmpty && rpId.isNotEmpty) {
      addCandidate('$rpId/api/auth');
    }
    return candidates;
  }

  bool _hasExplicitEnrollmentBaseUrl(Map<String, dynamic> payload) {
    return ((payload['api_base_url'] as String?)?.trim().isNotEmpty ?? false) ||
        ((payload['base_url'] as String?)?.trim().isNotEmpty ?? false) ||
        ((payload['enroll_url'] as String?)?.trim().isNotEmpty ?? false) ||
        (payload['api_base_urls'] is List &&
            (payload['api_base_urls'] as List).isNotEmpty);
  }

  bool _sameEnrollmentTarget(
    Map<String, dynamic> current,
    Map<String, dynamic> next,
  ) {
    final currentBaseUrls = _resolveApiBaseUrls(current).join('|');
    final nextBaseUrls = _resolveApiBaseUrls(next).join('|');
    return currentBaseUrls == nextBaseUrls &&
        ((current['rp_id'] as String?)?.trim() ?? '') ==
            ((next['rp_id'] as String?)?.trim() ?? '') &&
        ((current['email'] as String?)?.trim() ?? '') ==
            ((next['email'] as String?)?.trim() ?? '') &&
        ((current['enroll_token'] as String?)?.trim() ?? '') ==
            ((next['enroll_token'] as String?)?.trim() ?? '');
  }

  Future<void> _replaceStalePendingEnrollment(
    Map<String, dynamic> payload,
  ) async {
    final pending = _pendingPayload;
    if (pending == null || _sameEnrollmentTarget(pending, payload)) {
      return;
    }
    await _settings.clearPendingEnrollment();
    if (mounted) {
      setState(() {
        _pendingPayload = null;
      });
    }
  }

  String _defaultScheme(String host) {
    final lowered = host.toLowerCase();
    if (_allowHttpDev && _isLocalAddress(lowered)) {
      return 'http';
    }
    return 'https';
  }

  String _normalizeBaseUrl(String value) {
    try {
      final cleaned = _stripWhitespace(value);
      final uri = Uri.parse(cleaned);
      final scheme = uri.scheme.isEmpty ? 'https' : uri.scheme;
      final host = uri.host.isEmpty ? uri.path : uri.host;
      final port = uri.hasPort ? ':${uri.port}' : '';
      final path = uri.path;
      if (path.contains('/api/auth')) {
        return '$scheme://$host$port/api/auth';
      }
      if (path.endsWith('/enroll')) {
        final trimmed = path.substring(0, path.length - '/enroll'.length);
        return '$scheme://$host$port$trimmed';
      }
      if (path.isNotEmpty && path != '/') {
        return '$scheme://$host$port$path';
      }
      return '$scheme://$host$port/api/auth';
    } catch (_) {
      return '';
    }
  }

  String _stripWhitespace(String value) {
    return value.replaceAll(RegExp(r'\s+'), '');
  }

  String _normalizeSecret(String value) {
    return value.replaceAll(RegExp(r'\s+'), '').toUpperCase();
  }

  bool _looksLikeBase32(String value) {
    return RegExp(r'^[A-Z2-7]+=*$').hasMatch(value);
  }

  Map<String, String>? _parseOtpauth(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'otpauth') {
      return null;
    }
    final secret = (uri.queryParameters['secret'] ?? '').trim();
    if (secret.isEmpty) {
      return null;
    }
    String issuer = (uri.queryParameters['issuer'] ?? '').trim();
    String account = '';
    if (uri.path.isNotEmpty) {
      final label = Uri.decodeComponent(uri.path.replaceFirst('/', ''));
      if (label.contains(':')) {
        final parts = label.split(':');
        if (issuer.isEmpty) {
          issuer = parts.first.trim();
        }
        account = parts.sublist(1).join(':').trim();
      } else {
        account = label.trim();
      }
    }
    return {
      'secret': secret,
      'issuer': issuer,
      'account': account,
    };
  }

  Future<Map<String, dynamic>?> _tryParseEnrollmentPayload(String raw) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic> &&
            decoded['type'] == 'zt_totp_enroll') {
          return decoded;
        }
      } catch (_) {
        return null;
      }
    }
    final url = Uri.tryParse(trimmed);
    if (url != null && url.scheme.startsWith('http')) {
      final client = ApiClient(
        baseUrl: '${url.scheme}://${url.authority}',
        allowInsecureTls: _allowInsecureTls,
      );
      try {
        final path = url.hasQuery ? '${url.path}?${url.query}' : url.path;
        final response = await client.get(path);
        if (response.statusCode != 200) {
          return null;
        }
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic> &&
            decoded['type'] == 'zt_totp_enroll') {
          final enriched = Map<String, dynamic>.from(decoded);
          enriched.putIfAbsent(
            'enroll_url',
            () => '${url.scheme}://${url.authority}${url.path}',
          );
          return enriched;
        }
      } catch (_) {
        return null;
      } finally {
        client.close();
      }
    }

    const prefix = 'ZTENROLL:';
    if (!trimmed.toUpperCase().startsWith(prefix)) {
      return null;
    }
    final payloadPart =
        trimmed.substring(prefix.length).replaceAll(RegExp(r'\s+'), '').trim();
    if (payloadPart.isEmpty) {
      return null;
    }
    try {
      final decodedBytes = base64Url.decode(base64Url.normalize(payloadPart));
      final decodedJson = utf8.decode(decodedBytes);
      final decoded = jsonDecode(decodedJson);
      if (decoded is Map<String, dynamic> &&
          decoded['type'] == 'zt_totp_enroll') {
        return decoded;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<void> _submitSetupKey() async {
    if (_loading) {
      return;
    }
    final raw = _setupKeyController.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _status = 'Enter an enrollment code or otpauth URI.';
      });
      return;
    }

    final enrollmentPayload = await _tryParseEnrollmentPayload(raw);
    if (enrollmentPayload != null) {
      await _startEnrollment(_prepareEnrollmentPayload(enrollmentPayload));
      return;
    }

    final parsed = _parseOtpauth(raw);
    var secret = parsed?['secret'] ?? raw;
    var issuer = parsed?['issuer'] ?? '';
    var account = parsed?['account'] ?? '';

    secret = _normalizeSecret(secret);
    if (secret.isEmpty || !_looksLikeBase32(secret)) {
      setState(() {
        _status = 'Setup key must be a valid base32 secret.';
      });
      return;
    }
    if (issuer.isEmpty) {
      issuer = 'Local';
    }

    final record = TotpRecord(
      issuer: issuer,
      account: account,
      secret: secret,
      userId: '',
      rpId: '',
      deviceId: '',
      apiBaseUrl: '',
      keyId: '',
    );
    await _store.save(record);
    widget.onRegistered(TotpAccount.fromRecord(record));
    setState(() {
      _status = 'Setup key added.';
      _setupKeyController.clear();
    });
  }

  bool _isLoopbackHost(String host) {
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host.endsWith('.local') ||
        host.endsWith('.localdomain.com');
  }

  bool _isLocalAddress(String host) {
    return _isLoopbackHost(host) || RegExp(r'^[0-9.]+$').hasMatch(host);
  }

  String _buildKeyId(String rpId, String email) {
    final safeEmail = email.trim().toLowerCase();
    if (safeEmail.isEmpty) {
      return rpId.trim();
    }
    return '${rpId.trim()}|$safeEmail';
  }

  Future<void> _startEnrollment(Map<String, dynamic> payload) async {
    if (_isEnrollmentExpired(payload)) {
      await _settings.clearPendingEnrollment();
      if (mounted) {
        setState(() {
          _pendingPayload = null;
          _status = 'Enrollment expired. Scan a new QR code.';
        });
      }
      return;
    }
    await _replaceStalePendingEnrollment(payload);
    final email = (payload['email'] as String?)?.trim() ?? '';
    final rpId = (payload['rp_id'] as String?)?.trim() ?? '';
    final rpDisplayName =
        (payload['rp_display_name'] as String?)?.trim() ?? rpId;
    final issuer = (payload['issuer'] as String?)?.trim() ?? '';
    final accountName = (payload['account_name'] as String?)?.trim() ?? '';
    final enrollToken = (payload['enroll_token'] as String?)?.trim() ?? '';
    final deviceLabel =
        (payload['device_label'] as String?)?.trim() ?? 'Android Device';
    if (email.isEmpty ||
        rpId.isEmpty ||
        issuer.isEmpty ||
        accountName.isEmpty) {
      setState(() {
        _status = 'Enrollment QR is missing required fields.';
      });
      return;
    }

    final detectedBaseUrl = _resolveApiBaseUrl(payload);
    if (mounted) {
      setState(() {
        _detectedBaseUrl = detectedBaseUrl;
        if (detectedBaseUrl.isNotEmpty) {
          final host = Uri.tryParse(detectedBaseUrl)?.host ?? '';
          _connectivityHint = _isLoopbackHost(host)
              ? 'Tip: use a LAN IP or tunnel URL for mobile devices.'
              : '';
        }
      });
    }

    final keyId = _buildKeyId(rpId, email);
    if (await _store.containsKeyId(keyId)) {
      setState(() {
        _status =
            'This account is already registered. Remove the existing account before re-enrolling.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _status = 'Enrolling device...';
    });

    try {
      final candidateBaseUrls = <String>[];
      void addCandidate(String value) {
        final normalized = _coerceBaseUrl(value);
        if (normalized.isEmpty || candidateBaseUrls.contains(normalized)) {
          return;
        }
        candidateBaseUrls.add(normalized);
      }

      for (final baseUrl in _resolveApiBaseUrls(payload)) {
        addCandidate(baseUrl);
      }
      if (!_hasExplicitEnrollmentBaseUrl(payload)) {
        addCandidate(_rpBaseUrls[rpId] ?? '');
        addCandidate(widget.fallbackBaseUrl.trim());
      }

      if (candidateBaseUrls.isEmpty) {
        setState(() {
          _status = 'Enrollment needs a valid server URL.';
        });
        return;
      }
      final confirmedTarget = await _confirmEnrollmentTarget(
        rpDisplayName: rpDisplayName,
        rpId: rpId,
        issuer: issuer,
        accountName: accountName,
        email: email,
        candidateBaseUrls: candidateBaseUrls,
      );
      if (!mounted) {
        return;
      }
      if (!confirmedTarget) {
        setState(() {
          _status = 'Enrollment cancelled.';
        });
        return;
      }
      final publicKey = await _deviceCrypto.generateKeypair(
        rpId: rpId,
        keyId: keyId,
      );
      if (publicKey.isEmpty) {
        setState(() {
          _status = 'Key generation failed.';
        });
        return;
      }
      final enrollPayload = {
        'email': email,
        'device_label': deviceLabel,
        'platform': Platform.isIOS
            ? 'ios'
            : Platform.isAndroid
                ? 'android'
                : 'unknown',
        'rp_id': rpId,
        'rp_display_name': rpDisplayName,
        'key_type': 'p256',
        'public_key': publicKey,
      };
      if (enrollToken.isNotEmpty) {
        enrollPayload['enroll_token'] = enrollToken;
      }
      String? lastError;
      for (final baseUrl in candidateBaseUrls) {
        final enrollClient = ApiClient(
          baseUrl: baseUrl,
          allowInsecureTls: _allowInsecureTls,
        );
        try {
          final enrollResponse =
              await enrollClient.postJson('/enroll', enrollPayload);
          if (enrollResponse.statusCode != 200) {
            lastError = 'Enrollment failed: ${enrollResponse.body}';
            continue;
          }

          final enrollData =
              jsonDecode(enrollResponse.body) as Map<String, dynamic>;
          final userId = enrollData['user']['id'] as String;
          final deviceId = enrollData['device']['id'] as String;
          setState(() {
            _lastEmail = email;
            _lastRpId = rpId;
            _lastIssuer = issuer;
            _lastAccount = accountName;
            _lastUserId = userId;
            _lastDeviceId = deviceId;
            _status = 'Registering TOTP...';
          });

          final totpResponse = await enrollClient.postJson(
            '/totp/register',
            {
              'user_id': userId,
              'rp_id': rpId,
              'account_name': accountName,
              'issuer': issuer,
              'enroll_token': enrollToken,
            },
          );
          if (totpResponse.statusCode != 200) {
            lastError = 'TOTP registration failed: ${totpResponse.body}';
            continue;
          }
          final totpData =
              jsonDecode(totpResponse.body) as Map<String, dynamic>;
          setState(() {
            _recoveryCodes =
                (totpData['recovery_codes'] as List<dynamic>).cast<String>();
          });
          if (totpData['otpauth_uri'] != null) {
            final uri = Uri.parse(totpData['otpauth_uri'] as String);
            final secret = uri.queryParameters['secret'] ?? '';
            final label =
                uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
            if (secret.isNotEmpty) {
              final record = TotpRecord(
                issuer: issuer,
                account: label.isEmpty ? accountName : label,
                secret: secret,
                userId: userId,
                rpId: rpId,
                deviceId: deviceId,
                apiBaseUrl: baseUrl,
                keyId: keyId,
              );
              await _store.save(record);
              widget.onRegistered(TotpAccount.fromRecord(record));
            }
          }

          await _settings.saveApiBaseUrl(baseUrl);
          widget.onBaseUrlDetected?.call(baseUrl);
          if (rpId.isNotEmpty) {
            await _settings.saveRpBaseUrl(rpId, baseUrl);
            if (mounted) {
              setState(() {
                _rpBaseUrls[rpId] = baseUrl;
              });
            }
          }

          setState(() {
            _status = 'Enrollment complete.';
          });
          await _settings.clearPendingEnrollment();
          setState(() {
            _pendingPayload = null;
          });
          if (_recoveryCodes.isNotEmpty && mounted) {
            await _showRecoveryCodesDialog();
          }
          return;
        } catch (error) {
          lastError = 'Error: $error';
          continue;
        } finally {
          enrollClient.close();
        }
      }

      setState(() {
        _status = lastError ?? 'Enrollment failed.';
      });
      await _settings.savePendingEnrollment(jsonEncode(payload));
      setState(() {
        _pendingPayload = payload;
      });
    } catch (error) {
      setState(() {
        _status = 'Error: $error';
      });
      await _settings.savePendingEnrollment(jsonEncode(payload));
      setState(() {
        _pendingPayload = payload;
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<bool> _confirmEnrollmentTarget({
    required String rpDisplayName,
    required String rpId,
    required String issuer,
    required String accountName,
    required String email,
    required List<String> candidateBaseUrls,
  }) async {
    final hosts = candidateBaseUrls
        .map((url) => Uri.tryParse(url)?.host ?? url)
        .toSet()
        .join(', ');
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text('$label: $value'),
        );
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: ZtIamColors.surface,
          title: const Text('Confirm enrollment'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'A QR code or enrollment link can be created by anyone. '
                  'Only continue if you recognize the server below as your '
                  'own bank or organization.',
                ),
                const SizedBox(height: 12),
                row('Organization', rpDisplayName),
                row('Relying party ID', rpId),
                row('Issuer', issuer),
                row('Account', accountName),
                row('Email', email),
                row('Server', hosts.isEmpty ? 'unknown' : hosts),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Enroll'),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  Future<void> _showRecoveryCodesDialog() async {
    final codes = List<String>.from(_recoveryCodes);
    var acknowledged = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              backgroundColor: ZtIamColors.surface,
              title: const Text('Save your recovery codes'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'These codes are shown once. Store them somewhere safe '
                      '— you will need one if you lose this device.',
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: ZtIamColors.input,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: ZtIamColors.inputBorder),
                      ),
                      child: SelectableText(
                        codes.join('\n'),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          color: ZtIamColors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Checkbox(
                          value: acknowledged,
                          onChanged: (value) {
                            setDialogState(() {
                              acknowledged = value ?? false;
                            });
                          },
                        ),
                        const Expanded(
                          child: Text("I've saved these recovery codes."),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: codes.join('\n')),
                    );
                    if (dialogContext.mounted) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        const SnackBar(
                          content: Text('Recovery codes copied.'),
                        ),
                      );
                    }
                  },
                  child: const Text('Copy all'),
                ),
                TextButton(
                  onPressed: acknowledged
                      ? () => Navigator.of(dialogContext).pop()
                      : null,
                  child: const Text('Done'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('TOTP Setup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader(
            title: 'Enrollment QR',
            subtitle: 'Scan a single QR to enroll and register TOTP.',
          ),
          if (_pendingPayload != null) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Pending enrollment detected',
                      style: TextStyle(
                        color: ZtIamColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Retry enrollment when the connection improves.',
                      style: TextStyle(color: ZtIamColors.textSecondary),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: _loading
                          ? null
                          : () async {
                              final payload = _pendingPayload;
                              if (payload != null) {
                                await _startEnrollment(payload);
                              }
                            },
                      child: const Text('Retry enrollment'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () async {
                              await _settings.clearPendingEnrollment();
                              setState(() {
                                _pendingPayload = null;
                                _status = 'Pending enrollment cleared.';
                              });
                            },
                      child: const Text('Clear pending enrollment'),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _loading ? null : _scanQr,
            child: Text(_loading ? 'Working...' : 'Scan Enrollment QR'),
          ),
          if (_detectedBaseUrl.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'API: $_detectedBaseUrl',
              style: const TextStyle(color: ZtIamColors.textSecondary),
            ),
            if (_connectivityHint.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                _connectivityHint,
                style: const TextStyle(color: ZtIamColors.textMuted),
              ),
            ],
          ],
          const SizedBox(height: 20),
          const _SectionHeader(
            title: 'Setup key',
            subtitle: 'Paste the enrollment link or a base32 secret.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _setupKeyController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Setup key or payload',
              hintText: 'https://.../enroll-code/XXXX or otpauth://totp/...',
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _loading ? null : _submitSetupKey,
            child: const Text('Add code'),
          ),
          const SizedBox(height: 4),
          const Text(
            'Manual base32 setup is local-only and will show as Local.',
            style: TextStyle(color: ZtIamColors.textMuted),
          ),
          const SizedBox(height: 12),
          if (_lastUserId.isNotEmpty || _lastDeviceId.isNotEmpty) ...[
            const _SectionHeader(
              title: 'Enrollment Summary',
              subtitle: 'Stored locally for verification.',
            ),
            const SizedBox(height: 8),
            Text('Email: $_lastEmail',
                style: const TextStyle(color: ZtIamColors.textSecondary)),
            Text('RP ID: $_lastRpId',
                style: const TextStyle(color: ZtIamColors.textSecondary)),
            Text('Account: $_lastAccount',
                style: const TextStyle(color: ZtIamColors.textSecondary)),
            Text('Issuer: $_lastIssuer',
                style: const TextStyle(color: ZtIamColors.textSecondary)),
            Text('User ID: $_lastUserId',
                style: const TextStyle(color: ZtIamColors.textSecondary)),
            Text('Device ID: $_lastDeviceId',
                style: const TextStyle(color: ZtIamColors.textSecondary)),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 12),
          Text(_status, style: const TextStyle(color: ZtIamColors.textSecondary)),
        ],
      ),
    );
  }
}

class LoginApprovalsScreen extends StatefulWidget {
  const LoginApprovalsScreen({
    super.key,
    required this.accounts,
    required this.deviceCrypto,
    required this.allowInsecureTls,
    required this.fallbackBaseUrl,
    required this.allowHttpDev,
    required this.rpBaseUrls,
  });

  final List<TotpAccount> accounts;
  final DeviceCrypto deviceCrypto;
  final bool allowInsecureTls;
  final String fallbackBaseUrl;
  final bool allowHttpDev;
  final Map<String, String> rpBaseUrls;

  @override
  State<LoginApprovalsScreen> createState() => _LoginApprovalsScreenState();
}

class _LoginApprovalsScreenState extends State<LoginApprovalsScreen> {
  String _status = '';
  bool _loading = false;
  Map<String, dynamic>? _pending;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  TotpAccount? _matchAccount(Map<String, dynamic> pending) {
    final rpId = pending['rp_id'] as String? ?? '';
    final deviceId = pending['device_id'] as String? ?? '';
    for (final account in widget.accounts) {
      if (_sameRpFamily(account.rpId, rpId) && account.deviceId == deviceId) {
        return account;
      }
    }
    return null;
  }

  bool _sameRpFamily(String left, String right) {
    final a = left.trim().toLowerCase();
    final b = right.trim().toLowerCase();
    if (a == b) {
      return true;
    }
    const aliases = {'zt-iam.com', 'ztiam.com', 'zt-aim.com'};
    return aliases.contains(a) && aliases.contains(b);
  }

  bool _isLocalHost(String host) {
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        RegExp(r'^[0-9.]+$').hasMatch(host) ||
        host.endsWith('.local') ||
        host.endsWith('.localdomain.com');
  }

  bool _looksLikeHost(String host) {
    return host.contains('.') ||
        host == 'localhost' ||
        RegExp(r'^[0-9.]+$').hasMatch(host);
  }

  String _coerceBaseUrl(String raw) {
    final trimmed = raw.trim();
    final uri = Uri.tryParse(trimmed);
    if (trimmed.isEmpty || uri == null) {
      return trimmed;
    }
    return trimmed;
  }

  String _resolveAccountBaseUrl(TotpAccount account) {
    final rpId = account.rpId.trim();
    final mapped = widget.rpBaseUrls[rpId]?.trim() ?? '';
    if (mapped.isNotEmpty) {
      return _coerceBaseUrl(mapped);
    }
    if (account.apiBaseUrl.trim().isNotEmpty) {
      return _coerceBaseUrl(account.apiBaseUrl.trim());
    }
    if (rpId.isNotEmpty && _looksLikeHost(rpId)) {
      final scheme =
          widget.allowHttpDev && _isLocalHost(rpId) ? 'http' : 'https';
      return '$scheme://$rpId/api/auth';
    }
    if (widget.fallbackBaseUrl.trim().isNotEmpty) {
      return _coerceBaseUrl(widget.fallbackBaseUrl);
    }
    return '';
  }

  Future<Map<String, dynamic>?> _accountGet(
      TotpAccount account, String path) async {
    final baseUrl = _resolveAccountBaseUrl(account);
    if (baseUrl.isEmpty) {
      return null;
    }
    final client =
        ApiClient(baseUrl: baseUrl, allowInsecureTls: widget.allowInsecureTls);
    try {
      final response = await client.get(path);
      if (response.statusCode != 200) {
        return null;
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>?> _accountPost(
    TotpAccount account,
    String path,
    Map<String, dynamic> payload,
  ) async {
    final baseUrl = _resolveAccountBaseUrl(account);
    if (baseUrl.isEmpty) {
      return null;
    }
    final client =
        ApiClient(baseUrl: baseUrl, allowInsecureTls: widget.allowInsecureTls);
    try {
      final response = await client.postJson(path, payload);
      if (response.statusCode != 200) {
        return null;
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _status = '';
    });
    try {
      final candidates = widget.accounts
          .where((account) => account.userId.isNotEmpty)
          .toList(growable: false);
      final futures = candidates
          .map(
            (account) => _accountGet(
              account,
              '/login/pending?${Uri(queryParameters: {
                    'user_id': account.userId,
                    'device_id': account.deviceId,
                    'rp_id': account.rpId,
                  }).query}',
            ).timeout(const Duration(seconds: 2), onTimeout: () => null),
          )
          .toList(growable: false);
      final results = await Future.wait(futures);
      final hadResponse = results.any((data) => data != null);
      final pending = results.firstWhere(
        (data) => data != null && data['status'] == 'pending',
        orElse: () => null,
      );
      if (pending != null) {
        setState(() {
          _pending = pending;
        });
        return;
      }
      setState(() {
        _pending = null;
        if (hadResponse) {
          _status = 'No pending logins.';
        } else {
          _status = 'No pending logins.';
        }
      });
    } catch (error) {
      setState(() {
        _status = 'Error: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _approve() async {
    final pending = _pending;
    if (pending == null) {
      return;
    }
    final account = _matchAccount(pending);
    if (account == null) {
      setState(() {
        _status = 'No matching account for this login.';
      });
      return;
    }
    final loginId = pending['login_id'] as String? ?? '';
    final nonce = pending['nonce'] as String? ?? '';
    if (loginId.isEmpty || nonce.isEmpty) {
      setState(() {
        _status = 'Pending login is missing data.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _status = '';
    });
    try {
      final otp = account.currentCode();
      final pendingRp = (pending['rp_id'] as String? ?? account.rpId).trim();
      final pendingDevice =
          (pending['device_id'] as String? ?? account.deviceId).trim();
      final signature = await widget.deviceCrypto.sign(
        rpId: pendingRp,
        nonce: nonce,
        deviceId: pendingDevice,
        otp: otp,
        keyId: account.keyId.isEmpty ? account.rpId : account.keyId,
      );
      final response = await _accountPost(account, '/login/approve', {
        'login_id': loginId,
        'device_id': pendingDevice,
        'rp_id': pendingRp,
        'otp': otp,
        'nonce': nonce,
        'signature': signature,
      });
      setState(() {
        _status = response == null ? 'Sign failed.' : 'Sign: ok';
      });
      await _refresh();
    } catch (error) {
      setState(() {
        _status = 'Error: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _deny() async {
    final pending = _pending;
    if (pending == null) {
      return;
    }
    final account = _matchAccount(pending);
    if (account == null) {
      setState(() {
        _status = 'No matching account for this login.';
      });
      return;
    }
    final loginId = pending['login_id'] as String? ?? '';
    final nonce = pending['nonce'] as String? ?? '';
    final pendingRp = (pending['rp_id'] as String? ?? account.rpId).trim();
    final pendingDevice =
        (pending['device_id'] as String? ?? account.deviceId).trim();
    if (loginId.isEmpty || nonce.isEmpty) {
      return;
    }
    setState(() {
      _loading = true;
      _status = '';
    });
    try {
      final signature = await widget.deviceCrypto.sign(
        rpId: pendingRp,
        nonce: nonce,
        deviceId: pendingDevice,
        otp: 'login-deny:$loginId',
        keyId: account.keyId.isEmpty ? account.rpId : account.keyId,
      );
      final response = await _accountPost(account, '/login/deny', {
        'login_id': loginId,
        'device_id': pendingDevice,
        'rp_id': pendingRp,
        'nonce': nonce,
        'signature': signature,
        'reason': 'user_denied',
      });
      setState(() {
        _status = response == null ? 'Denied failed.' : 'Denied: ok';
      });
      await _refresh();
    } catch (error) {
      setState(() {
        _status = 'Error: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _clearPending() async {
    setState(() {
      _loading = true;
      _status = '';
    });
    try {
      final pending = _pending;
      final account = pending == null ? null : _matchAccount(pending);
      if (account == null) {
        setState(() {
          _status = 'No pending login to clear.';
        });
        return;
      }
      final loginId = pending?['login_id'] as String? ?? '';
      final nonce = pending?['nonce'] as String? ?? '';
      final pendingRp = (pending?['rp_id'] as String? ?? account.rpId).trim();
      final pendingDevice =
          (pending?['device_id'] as String? ?? account.deviceId).trim();
      if (loginId.isEmpty || nonce.isEmpty) {
        setState(() {
          _status = 'Pending login is missing data.';
        });
        return;
      }
      final signature = await widget.deviceCrypto.sign(
        rpId: pendingRp,
        nonce: nonce,
        deviceId: pendingDevice,
        otp: 'login-clear:${account.userId}',
        keyId: account.keyId.isEmpty ? account.rpId : account.keyId,
      );
      final response = await _accountPost(account, '/login/clear', {
        'user_id': account.userId,
        'login_id': loginId,
        'device_id': pendingDevice,
        'rp_id': pendingRp,
        'nonce': nonce,
        'signature': signature,
      });
      await _refresh();
      setState(() {
        _status = response != null
            ? 'Pending approvals cleared.'
            : 'Clear pending failed.';
      });
    } catch (error) {
      setState(() {
        _status = 'Error: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    return Scaffold(
      appBar: AppBar(title: const Text('Login approvals')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader(
            title: 'Pending login',
            subtitle: 'Sign or deny login requests.',
          ),
          const SizedBox(height: 16),
          if (pending == null)
            Text(_status, style: const TextStyle(color: ZtIamColors.textSecondary)),
          if (pending != null) ...[
            Text('Login ID: ${pending['login_id']}',
                style: const TextStyle(color: ZtIamColors.textSecondary)),
            Text('RP ID: ${pending['rp_id']}',
                style: const TextStyle(color: ZtIamColors.textSecondary)),
            Text('Device ID: ${pending['device_id']}',
                style: const TextStyle(color: ZtIamColors.textSecondary)),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ZtIamColors.danger,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _loading ? null : _deny,
                    child: const Text('Deny'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ZtIamColors.accentGreen,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _loading ? null : _approve,
                    child: const Text('Sign'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(_status, style: const TextStyle(color: ZtIamColors.textSecondary)),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
                  onPressed: _loading ? null : _refresh,
                  child: const Text('Refresh'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ZtIamColors.card,
                    foregroundColor: ZtIamColors.textPrimary,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  onPressed: _loading ? null : _clearPending,
                  child: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'Clear pending',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Section header used across screens.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 18, color: ZtIamColors.textPrimary),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(color: ZtIamColors.textSecondary),
        ),
      ],
    );
  }
}
