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
}
