import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zt_totp_mobile/main.dart';

void main() {
  testWidgets('authenticator home screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const ZtAuthenticatorApp());
    expect(find.text('ZT-Authenticator'), findsOneWidget);
  });

  test('explicit HTTPS enrollment URLs are never downgraded', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(source, isNot(contains("replace(scheme: 'http')")));
    expect(
      source,
      contains("final scheme = uri.scheme.isEmpty ? 'https' : uri.scheme;"),
    );
  });

  test('release manifest permits authenticator network access', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(
      manifest,
      contains('android.permission.INTERNET'),
      reason: 'Release APKs must be able to resolve and contact RP hosts.',
    );
    expect(manifest, contains('android.permission.ACCESS_NETWORK_STATE'));
  });

  test('HTTP client preserves TLS hostname during DNS fallback', () {
    final source = File('lib/http_client.dart').readAsStringSync();
    expect(source, contains('NetworkResolver.resolveHost(uri.host)'));
    expect(source, contains('SecureSocket.secure('));
    expect(source, contains('host: uri.host'));
    expect(source, isNot(contains('badCertificateCallback =')));
  });

  test('pending enrollment is expiry checked and token bound', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(source, contains('_isEnrollmentExpired(payload)'));
    expect(source, contains("'enroll_token': enrollToken"));
    expect(source, contains('_replaceStalePendingEnrollment(payload)'));
    expect(source, contains('_hasExplicitEnrollmentBaseUrl(payload)'));
    expect(source, contains('_resolveApiBaseUrls(payload)'));
    expect(
        source, contains('Previous enrollment expired. Scan a new QR code.'));
  });

  test('explicit enrollment server URL is authoritative', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(source, contains('if (!_hasExplicitEnrollmentBaseUrl(payload))'));
    expect(source, contains("payload['api_base_urls']"));
    expect(source, contains('addCandidate(_rpBaseUrls[rpId] ?? \'\')'));
    expect(source, contains('addCandidate(widget.fallbackBaseUrl.trim())'));
  });

  test('PoIA labels expose security-relevant context clearly', () {
    expect(poiaIntentLabel('user_id'), 'Authorizing user');
    expect(poiaIntentLabel('workflow_id'), 'Workflow');
    expect(poiaIntentLabel('rp_id'), 'Relying party');
    expect(poiaIntentLabel('custom_field'), 'Custom field');
    expect(poiaIntentValue({'tenant': 'alpha'}), '{"tenant":"alpha"}');
  });

  test('login approval errors explain key recovery and expiry', () {
    expect(
      loginApprovalErrorMessage(
        PlatformException(code: 'sign_failed', message: 'No key for rp_id'),
      ),
      contains('enroll it again'),
    );
    expect(
      loginApprovalResponseMessage({'status': 'denied', 'reason': 'expired'}),
      contains('expired'),
    );
    expect(
      loginApprovalResponseMessage(
        {'status': 'denied', 'reason': 'invalid_device_proof'},
      ),
      contains('no longer matches'),
    );
  });
}
