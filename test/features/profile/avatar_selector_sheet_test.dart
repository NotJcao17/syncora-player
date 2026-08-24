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

    testWidgets('Renders AvatarSelectorSheet in isDialog mode with close button', (tester) async {
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
                isDialog: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Elige tu Avatar'), findsOneWidget);
      expect(find.byType(IconButton), findsOneWidget);
    });

    testWidgets('AvatarSelectorSheet.show opens Dialog on desktop', (tester) async {
      tester.view.physicalSize = const Size(1280, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => AvatarSelectorSheet.show(context, currentSeed: 'cosmic-wolf'),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Elige tu Avatar'), findsOneWidget);
    });
  });
}
