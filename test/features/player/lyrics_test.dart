import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/apis/lrclib_api.dart';
import 'package:syncora_player/data/apis/lrclib_provider.dart';
import 'package:syncora_player/features/player/audio_engine/audio_engine_state.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/player_providers.dart';
import 'package:syncora_player/features/player/syncora_player_controller.dart';
import 'package:syncora_player/features/player/widgets/desktop_lyrics_view.dart';
import 'package:syncora_player/features/player/widgets/lyrics_sheet.dart';

import 'mini_player_test.dart';

class FakeLrcLibApi implements LRCLibApi {
  final LRCLibResult? mockResult;

  FakeLrcLibApi({this.mockResult});

  @override
  Future<LRCLibResult?> getLyrics({
    required String cacheKey,
    required String trackTitle,
    required String artistName,
    required int durationSec,
  }) async {
    return mockResult;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const testTrack = SyncoraTrack(
    id: 't_lrc_1',
    title: 'Test Song',
    artist: 'Test Artist',
    album: 'Test Album',
    duration: Duration(seconds: 200),
  );

  final syncedResult = LRCLibResult(
    plainLyrics: 'Line 1\nLine 2\nLine 3',
    syncedLyrics: '[00:10.00]First line\n[00:20.00]Second line\n[00:30.00]Third line',
    lines: const [
      LrcLine(timestamp: Duration(seconds: 10), text: 'First line'),
      LrcLine(timestamp: Duration(seconds: 20), text: 'Second line'),
      LrcLine(timestamp: Duration(seconds: 30), text: 'Third line'),
    ],
  );

  group('LyricsSheet Click-To-Seek Tests', () {
    testWidgets('Tapping synced line triggers seek to timestamp in LyricsSheet', (tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeEngine = FakeAudioEngine();
      final fakeExtraction = FakeExtractionService();
      final controller = SyncoraPlayerController(
        engine: fakeEngine,
        extractionService: fakeExtraction,
      );

      final fakeLrcApi = FakeLrcLibApi(mockResult: syncedResult);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncoraPlayerControllerProvider.overrideWith((ref) => controller),
            lrcLibApiProvider.overrideWithValue(fakeLrcApi),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: LyricsSheet(track: testTrack),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('First line'), findsOneWidget);
      expect(find.text('Second line'), findsOneWidget);
      expect(find.text('Third line'), findsOneWidget);

      // Tap on the second line (timestamp: 20s)
      await tester.tap(find.text('Second line'));
      await tester.pump();

      expect(fakeEngine.position, const Duration(seconds: 20));
    });
  });

  group('DesktopLyricsView Tests', () {
    testWidgets('Renders DesktopLyricsView with synced lines and click-to-seek', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeEngine = FakeAudioEngine();
      final fakeExtraction = FakeExtractionService();
      final controller = SyncoraPlayerController(
        engine: fakeEngine,
        extractionService: fakeExtraction,
      );

      final fakeLrcApi = FakeLrcLibApi(mockResult: syncedResult);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncoraPlayerControllerProvider.overrideWith((ref) => controller),
            lrcLibApiProvider.overrideWithValue(fakeLrcApi),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: DesktopLyricsView(track: testTrack),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Test Song'), findsOneWidget);
      expect(find.text('Test Artist'), findsOneWidget);
      expect(find.text('First line'), findsOneWidget);
      expect(find.text('Second line'), findsOneWidget);
      expect(find.text('Third line'), findsOneWidget);

      // Click to seek third line (timestamp: 30s)
      await tester.tap(find.text('Third line'));
      await tester.pump();

      expect(fakeEngine.position, const Duration(seconds: 30));
    });

    testWidgets('Renders plain lyrics if not synced', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeEngine = FakeAudioEngine();
      final fakeExtraction = FakeExtractionService();
      final controller = SyncoraPlayerController(
        engine: fakeEngine,
        extractionService: fakeExtraction,
      );

      const plainResult = LRCLibResult(
        plainLyrics: 'Just plain lyrics text without timestamps',
      );

      final fakeLrcApi = FakeLrcLibApi(mockResult: plainResult);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncoraPlayerControllerProvider.overrideWith((ref) => controller),
            lrcLibApiProvider.overrideWithValue(fakeLrcApi),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: DesktopLyricsView(track: testTrack),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Just plain lyrics text without timestamps'), findsOneWidget);
    });

    testWidgets('Renders empty state when lyrics not found', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeEngine = FakeAudioEngine();
      final fakeExtraction = FakeExtractionService();
      final controller = SyncoraPlayerController(
        engine: fakeEngine,
        extractionService: fakeExtraction,
      );

      final fakeLrcApi = FakeLrcLibApi(mockResult: null);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncoraPlayerControllerProvider.overrideWith((ref) => controller),
            lrcLibApiProvider.overrideWithValue(fakeLrcApi),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: DesktopLyricsView(track: testTrack),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('No se encontraron letras para esta canción'), findsOneWidget);
    });
  });
}
