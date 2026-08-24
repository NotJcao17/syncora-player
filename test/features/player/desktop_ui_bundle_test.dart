import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/theme/app_icons.dart';
import 'package:syncora_player/core/widgets/track_tile.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/player_providers.dart';
import 'package:syncora_player/features/player/syncora_player_controller.dart';
import 'package:syncora_player/features/player/widgets/mini_player.dart';
import 'package:syncora_player/features/search/screens/search_screen.dart';

import 'mini_player_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const testTrack = SyncoraTrack(
    id: 't_dt_1',
    title: 'Short Title',
    artist: 'Artist One',
    album: 'Album One',
    duration: Duration(seconds: 180),
  );

  group('Bundle 2 Desktop UI & Styling Tests', () {
    testWidgets('MiniPlayer desktop renders dynamic heart next to title and fixed height slider', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeEngine = FakeAudioEngine();
      final fakeExtraction = FakeExtractionService();
      final controller = SyncoraPlayerController(
        engine: fakeEngine,
        extractionService: fakeExtraction,
      );

      controller.setQueue([testTrack], startIndex: 0, autoplay: false);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncoraPlayerControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: MiniPlayer(),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Short Title'), findsOneWidget);
      expect(find.text('Artist One'), findsOneWidget);

      // Heart button is present
      final heartFinder = find.byIcon(AppIcons.broken(SolarIcons.Heart));
      expect(heartFinder, findsWidgets);

      // Sliders are present (progress + volume)
      final sliderFinder = find.byType(Slider);
      expect(sliderFinder, findsNWidgets(2));
    });

    testWidgets('TrackTile uses pure white color for active playing track', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeEngine = FakeAudioEngine();
      final fakeExtraction = FakeExtractionService();
      final controller = SyncoraPlayerController(
        engine: fakeEngine,
        extractionService: fakeExtraction,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncoraPlayerControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: TrackTile(
                track: testTrack,
                index: 0,
                isPlaying: true,
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final titleWidget = tester.widget<Text>(find.text('Short Title'));
      expect(titleWidget.style?.color, Colors.white);
    });

    testWidgets('SearchScreen renders search header and popular toggle container', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SearchScreen(),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Buscar'), findsOneWidget);
      expect(find.byType(SearchScreen), findsOneWidget);
    });
  });
}
