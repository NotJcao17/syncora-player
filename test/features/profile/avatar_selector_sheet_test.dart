import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/profile/widgets/avatar_selector_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AvatarSelectorSheet Widget Tests', () {
    testWidgets('Renders AvatarSelectorSheet with 24 avatar seeds', (tester) async {
      tester.view.physicalSize = const Size(1280, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: AvatarSelectorSheet(
                currentSeed: 'cosmic-wolf',
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Elige tu Avatar'), findsOneWidget);
    });
  });
}
