import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SyncoraApp smoke test', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(
        child: SyncoraApp(),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.text('Hecho para ti'), findsOneWidget);
    expect(find.text('Reproducidos recientemente'), findsOneWidget);
  });
}
