import 'dart:io';

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

  test('pending enrollment is expiry checked and token bound', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(source, contains('_isEnrollmentExpired(payload)'));
    expect(source, contains("'enroll_token': enrollToken"));
    expect(
        source, contains('Previous enrollment expired. Scan a new QR code.'));
  });

  test('PoIA labels expose security-relevant context clearly', () {
    expect(poiaIntentLabel('user_id'), 'Authorizing user');
    expect(poiaIntentLabel('workflow_id'), 'Workflow');
    expect(poiaIntentLabel('rp_id'), 'Relying party');
    expect(poiaIntentLabel('custom_field'), 'Custom field');
    expect(poiaIntentValue({'tenant': 'alpha'}), '{"tenant":"alpha"}');
  });
}
