import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zt_totp_mobile/amount_words.dart';
import 'package:zt_totp_mobile/poia_intent_view.dart';
import 'package:zt_totp_mobile/main.dart';
import 'package:zt_totp_mobile/zt_theme.dart';

void main() {
  testWidgets('transfer avatars and names are prominent without duplicating recipient', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(
      body: PoiaIntentSummary(youLabel: 'Alice', displayFields: [
        MapEntry('Action', 'transfer'), MapEntry('recipient', 'Robert'),
        MapEntry('amount', '100'), MapEntry('currency', 'USD'),
      ]),
    )));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.person_rounded), findsNWidgets(2));
    for (final avatar in tester.widgetList<CircleAvatar>(find.byType(CircleAvatar))) {
      expect(avatar.radius, 26);
      expect(avatar.backgroundColor!.computeLuminance(), greaterThan(0.5));
    }
    for (final name in ['Alice', 'Robert']) {
      expect(find.text(name), findsOneWidget);
      final text = tester.widget<Text>(find.text(name));
      expect(text.style!.fontSize, 16);
      expect(text.style!.fontWeight, FontWeight.w700);
      expect(text.style!.color, ZtIamColors.textPrimary);
    }
    expect(tester.takeException(), isNull);
  });

  test('amount words preserve fractional changes without currency rounding', () {
    expect(exactAmountWords('150000', 'JPY'), 'One hundred and fifty thousand Japanese yen');
    expect(exactAmountWords('100.01', 'JPY'), 'One hundred point zero one Japanese yen');
    expect(exactAmountWords('-0.01', 'USD'), 'Negative zero point zero one US dollars');
    expect(exactAmountWords('1e20', 'USD'), isNull);
    expect(exactAmountWords('1', 'UNKNOWN'), isNull);
  });

  test('account display removes only its known issuer prefix', () {
    final account = TotpAccount(issuer: 'PoIA Bank', account: 'PoIA Bank:long.email@example.test',
        secret: 'JBSWY3DPEHPK3PXP', userId: '1', rpId: 'poia-demo-bank', deviceId: '1', apiBaseUrl: '', keyId: '');
    expect(account.displayAccount(), 'long.email@example.test');
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('intent dialog fits narrow screen at text scale $scale', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const fields = [MapEntry('Action', 'transfer'),
        MapEntry('external account', '123456789012345678901234567890'),
        MapEntry('amount', '100.001'), MapEntry('currency', 'JPY'),
        MapEntry('from account', 'Checking 12345678'),
        MapEntry('purpose', 'Payment for the selected service'),
        MapEntry('rp id', 'poia-demo-bank')];
      await tester.pumpWidget(MaterialApp(home: MediaQuery(
        data: MediaQueryData(size: const Size(320, 640), textScaler: TextScaler.linear(scale)),
        child: const Scaffold(body: AlertDialog(content: SizedBox(width: double.maxFinite,
          child: SingleChildScrollView(child: PoiaIntentSummary(displayFields: fields))))))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('100.001 JPY'), findsOneWidget);
      expect(find.text('123456789012345678901234567890'), findsOneWidget);
    });
  }
}
