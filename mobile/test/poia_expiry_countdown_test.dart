import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zt_totp_mobile/poia_intent_view.dart';

void main() {
  testWidgets('counts down once, expires without negative time, and disposes', (tester) async {
    var now = DateTime.fromMillisecondsSinceEpoch(1000000);
    await tester.pumpWidget(MaterialApp(
      home: PoiaExpiryCountdown(expiresAt: 1060, now: () => now),
    ));
    expect(find.text('Expires in: 60s'), findsOneWidget);
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Expires in: 59s'), findsOneWidget);
    expect(find.text('Expires in: 60s'), findsNothing);
    now = now.add(const Duration(seconds: 70));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Expired'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('delayed display and resume use the original deadline', (tester) async {
    var now = DateTime.fromMillisecondsSinceEpoch(1040000);
    await tester.pumpWidget(MaterialApp(
      home: PoiaExpiryCountdown(expiresAt: 1060, now: () => now),
    ));
    expect(find.text('Expires in: 20s'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(seconds: 30));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('Expired'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
