import 'package:flutter_test/flutter_test.dart';

import 'package:zt_totp_mobile/main.dart';

void main() {
  testWidgets('authenticator home screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const ZtAuthenticatorApp());
    expect(find.text('ZT-Authenticator'), findsOneWidget);
  });
}
