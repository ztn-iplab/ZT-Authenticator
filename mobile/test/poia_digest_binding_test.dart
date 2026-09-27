import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zt_totp_mobile/main.dart';

void main() {
  Map<String, dynamic> vector() {
    const intent = '{"action":"transfer","scope":{"amount":50.0,"external_account":"9007"},"context":{"user_id":1}}';
    final proof = jsonEncode({'intent_hash': base64Url.encode(sha256.convert(utf8.encode(intent)).bytes), 'nonce': 'nonce-1', 'expires_at': 2000000000});
    return {'intent_canonical_json': intent, 'proof_payload_json': proof,
      'intent_hash': sha256.convert(utf8.encode(proof)).toString(),
      'nonce': 'nonce-1', 'expires_at': 2000000000};
  }

  test('verifies exact bytes without recanonicalizing integral floats', () {
    expect(validatedPoiaIntent(vector())['scope']['amount'], 50.0);
  });
  test('rejects modified intent bytes', () {
    final data = vector();
    data['intent_canonical_json'] = (data['intent_canonical_json'] as String).replaceAll('9007', '7781');
    expect(() => validatedPoiaIntent(data), throwsFormatException);
  });
  test('rejects nonce or digest substitution', () {
    for (final key in ['nonce', 'intent_hash']) {
      final data = vector();
      data[key] = 'substituted';
      expect(() => validatedPoiaIntent(data), throwsFormatException);
    }
  });
  test('does not render unbound server display fields', () {
    final data = vector();
    data['display_fields'] = [['Recipient', '7781']];
    final fields = verifiedDisplayFields(validatedPoiaIntent(data));
    expect(fields.any((pair) => pair[0] == 'external account' && pair[1] == '9007'), isTrue);
    expect(fields.any((pair) => pair[1] == '7781'), isFalse);
  });
  test('validity duration is replaced by the dialog countdown without mutating intent', () {
    final intent = {
      'action': 'transfer',
      'constraints': {'expires_in_seconds': 60, 'single_use': true},
    };
    final before = jsonEncode(intent);
    final fields = verifiedDisplayFields(intent);
    expect(fields.any((pair) => pair[0] == 'expires in seconds'), isFalse);
    expect(fields.any((pair) => pair[0] == 'single use'), isTrue);
    expect(jsonEncode(intent), before);
  });
}
