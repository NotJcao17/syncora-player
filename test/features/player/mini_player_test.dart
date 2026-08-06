import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/theme/app_icons.dart';
import 'package:syncora_player/core/extraction/extraction_service.dart';
import 'package:syncora_player/core/extraction/models/extraction_request.dart';
import 'package:syncora_player/core/extraction/models/extraction_result.dart';
import 'package:syncora_player/features/player/audio_engine/audio_engine_state.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/player_providers.dart';
import 'package:syncora_player/features/player/syncora_player_controller.dart';
import 'package:syncora_player/features/player/widgets/mini_player.dart';


class FakeAudioEngine implements AudioEngine {
  final _stateController = StreamController<AudioEngineState>.broadcast();
  final _completionController = StreamController<void>.broadcast();

  AudioEngineState _state = AudioEngineState.initial;

  @override
  Stream<AudioEngineState> get stateStream => _stateController.stream;

  @override
  Stream<void> get completionStream => _completionController.stream;

  @override
  Duration get position => _state.position;

  @override
  Duration get duration => _state.duration;

  void emitState(AudioEngineState newState) {
    _state = newState;
    _stateController.add(_state);
  }

  @override
  Future<void> setUrl(String url, {Map<String, String>? headers}) async {
    emitState(_state.copyWith(
      processingState: AudioProcessingState.ready,
      duration: const Duration(seconds: 180),
    ));
  }

  @override
  Future<void> play() async {
    emitState(_state.copyWith(playing: true));
  }

  @override
  Future<void> pause() async {
    emitState(_state.copyWith(playing: false));
  }

  @override
  Future<void> stop() async {
    emitState(_state.copyWith(
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
  }

  @override
  Future<void> seek(Duration position) async {
    emitState(_state.copyWith(position: position));
  }

  @override
  Future<void> setSpeed(double speed) async {
    emitState(_state.copyWith(speed: speed));
  }

  @override
  Future<void> setVolume(double volume) async {
    emitState(_state.copyWith(volume: volume));
  }

  @override
  Future<void> setSkipSilenceEnabled(bool enabled) async {}

  @override
  Future<void> dispose() async {
    await _stateController.close();
    await _completionController.close();
  }
}

class FakeExtractionService implements ExtractionService {
  @override
  Future<ExtractionResult> extractUrl(
    String videoId, {
    ExtractionPriority priority = ExtractionPriority.streaming,
  }) async {
    return const ExtractionSuccess(
      requestId: 'req_1',
      streamUrl: 'https://example.com/stream.mp3',
      headers: {},
    );
  }

  Future<void> initialize() async {}

  @override
  void dispose() {}

  @override
  void resetEngine() {}

  @override
  Stream<String> get onLogMessage => const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MiniPlayer Widget Tests', () {
    testWidgets('MiniPlayer está oculto si currentTrack == null', (tester) async {
      final mockEngine = FakeAudioEngine();
      final mockExtraction = FakeExtractionService();
      final controller = SyncoraPlayerController(
        engine: mockEngine,
        extractionService: mockExtraction,
      );

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
      await tester.pumpAndSettle();

      expect(find.text('Rick Astley'), findsNothing);
    });

    testWidgets('MiniPlayer es visible cuando hay una pista activa', (tester) async {
      final mockEngine = FakeAudioEngine();
      final mockExtraction = FakeExtractionService();
      final controller = SyncoraPlayerController(
        engine: mockEngine,
        extractionService: mockExtraction,
      );

      const track = SyncoraTrack(
        id: 't1',
        title: 'Never Gonna Give You Up',
        artist: 'Rick Astley',
        album: 'Album 1',
        duration: Duration(seconds: 213),
      );

      controller.setQueue([track], startIndex: 0);

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
      await tester.pumpAndSettle();

      expect(find.text('Never Gonna Give You Up'), findsOneWidget);
      expect(find.text('Rick Astley'), findsOneWidget);
    });

    testWidgets('Tocar Play/Pause cambia el estado', (tester) async {
      final mockEngine = FakeAudioEngine();
      final mockExtraction = FakeExtractionService();
      final controller = SyncoraPlayerController(
        engine: mockEngine,
        extractionService: mockExtraction,
      );
      controller.init();

      const track = SyncoraTrack(
        id: 't1',
        title: 'Never Gonna Give You Up',
        artist: 'Rick Astley',
        album: 'Album 1',
        duration: Duration(seconds: 213),
      );

      controller.setQueue([track], startIndex: 0, autoplay: false);

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
      await tester.pumpAndSettle();

      final playButton = find.byIcon(AppIcons.outline(SolarIcons.Play)).first;
      expect(playButton, findsOneWidget);

      await tester.tap(playButton);
      await tester.pumpAndSettle();

      expect(controller.state.engine.playing, isTrue);
    });
  });
}
