import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/extraction/extraction_service.dart';
import 'package:syncora_player/core/extraction/models/extraction_request.dart';
import 'package:syncora_player/core/extraction/models/extraction_result.dart';
import 'package:syncora_player/features/player/audio_engine/audio_engine_state.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/syncora_player_controller.dart';

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

  void triggerCompletion() {
    _completionController.add(null);
  }

  String? lastUrl;
  int setUrlCallCount = 0;

  @override
  Future<void> setUrl(String url, {Map<String, String>? headers}) async {
    lastUrl = url;
    setUrlCallCount++;
    emitState(_state.copyWith(
      processingState: AudioProcessingState.ready,
      duration: const Duration(seconds: 180),
    ));
  }

  @override
  Future<void> setLocalSource(String path) async {
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
  void dispose() {
    _stateController.close();
    _completionController.close();
  }
}

class TestableExtractionService implements ExtractionService {
  final StreamController<String> _logController = StreamController<String>.broadcast();
  int extractCount = 0;
  ExtractionError? forcedError;

  // Permite retener la resolución de un videoId concreto hasta que el test
  // la complete a mano — reproduce a voluntad la carrera de "extracción
  // vieja y lenta resuelve después de que el usuario ya cambió de pista".
  final Map<String, Completer<ExtractionResult>> _held = {};

  Completer<ExtractionResult> holdResolution(String videoId) {
    final completer = Completer<ExtractionResult>();
    _held[videoId] = completer;
    return completer;
  }

  @override
  Stream<String> get onLogMessage => _logController.stream;

  @override
  Future<ExtractionResult> extractUrl(
    String videoId, {
    String? trackTitle,
    String? trackArtist,
    int? durationSeconds,
    ExtractionPriority priority = ExtractionPriority.streaming,
  }) async {
    extractCount++;
    final held = _held.remove(videoId);
    if (held != null) {
      return held.future;
    }
    if (forcedError != null) {
      return ExtractionFailure(
        requestId: 'req_$extractCount',
        error: forcedError!,
        message: 'Forced error $forcedError',
      );
    }

    if (videoId == 'not_found_track') {
      return ExtractionFailure(
        requestId: 'req_$extractCount',
        error: ExtractionError.notFound,
        message: 'Track not found',
      );
    }

    return ExtractionSuccess(
      requestId: 'req_$extractCount',
      streamUrl: 'https://example.com/audio_$videoId.mp3',
      headers: const {},
    );
  }

  @override
  void resetEngine() {}

  @override
  void dispose() {
    _logController.close();
  }
}

void main() {
  group('SyncoraPlayerController Tests', () {
    late FakeAudioEngine engine;
    late TestableExtractionService extractionService;
    late SyncoraPlayerController controller;

    final testTracks = [
      const SyncoraTrack(id: 'track1', title: 'Track 1'),
      const SyncoraTrack(id: 'track2', title: 'Track 2'),
      const SyncoraTrack(id: 'track3', title: 'Track 3'),
    ];

    setUp(() {
      engine = FakeAudioEngine();
      extractionService = TestableExtractionService();
      controller = SyncoraPlayerController(
        engine: engine,
        extractionService: extractionService,
      );
      controller.init();
    });

    tearDown(() {
      controller.dispose();
    });

    test('1. Estado inicial es idle (no playing)', () {
      expect(controller.state.engine.playing, isFalse);
      expect(controller.state.queue, isEmpty);
      expect(controller.state.currentIndex, -1);
      expect(controller.state.currentTrack, isNull);
    });

    test('2. play() -> estado transiciona a playing', () async {
      await controller.setQueue(testTracks, autoplay: false);
      expect(controller.state.engine.playing, isFalse);

      await controller.play();
      expect(controller.state.engine.playing, isTrue);
    });

    test('3. pause() -> estado transiciona a paused', () async {
      await controller.setQueue(testTracks, autoplay: true);
      expect(controller.state.engine.playing, isTrue);

      await controller.pause();
      expect(controller.state.engine.playing, isFalse);
    });

    test('4. Error rateLimited persistente -> exactamente 1 reintento -> pausado (guard 403)', () async {
      extractionService.forcedError = ExtractionError.rateLimited;

      await controller.setQueue([testTracks[0]], autoplay: true);

      // Intento 1 + 1 reintento = 2 llamadas a extractUrl
      expect(extractionService.extractCount, 2);
      expect(controller.state.lastError, ExtractionError.rateLimited);
      expect(controller.state.engine.playing, isFalse);
    });

    test('5. Error notFound -> auto-skip inmediato (sin reintento)', () async {
      final queueWithBadTrack = [
        const SyncoraTrack(id: 'not_found_track', title: 'Bad Track'),
        const SyncoraTrack(id: 'track2', title: 'Track 2'),
      ];

      await controller.setQueue(queueWithBadTrack, autoplay: true);

      // notFound no debe reintentar la pista 1, debe hacer auto-skip a pista 2
      expect(controller.state.currentIndex, 1);
      expect(controller.state.currentTrack?.id, 'track2');
    });

    test('6. skipToNext() en cola de 3 -> currentIndex avanza', () async {
      await controller.setQueue(testTracks, autoplay: true);
      expect(controller.state.currentIndex, 0);

      await controller.skipToNext();
      expect(controller.state.currentIndex, 1);

      await controller.skipToNext();
      expect(controller.state.currentIndex, 2);
    });

    test('7. Repeat one -> al completarse, vuelve a la misma pista', () async {
      await controller.setQueue(testTracks, autoplay: true);
      controller.setRepeatMode(SyncoraRepeatMode.one);

      expect(controller.state.currentIndex, 0);

      // Simular evento de finalización del engine
      engine.triggerCompletion();
      await pumpEventQueue();

      expect(controller.state.currentIndex, 0);
      expect(controller.state.engine.playing, isTrue);
    });

    test(
        '8. Extracción vieja y lenta no pisa el motor tras un cambio de pista '
        'posterior (guard de generación, ver bug reportado en Fase C)', () async {
      await controller.setQueue(testTracks, autoplay: false);

      // track1 empieza a resolverse pero se queda "colgada" a propósito —
      // simula una extracción de Fase C que tarda mucho (varios candidatos,
      // varios clientes) porque la pista no tiene un match bueno y fácil.
      final held = extractionService.holdResolution('track1');
      final firstPlay = controller.playIndex(0);
      await pumpEventQueue();

      // Mientras la extracción de track1 sigue pendiente, el usuario cambia
      // a track2 — esta sí resuelve de inmediato.
      await controller.playIndex(1);
      expect(controller.state.currentIndex, 1);
      expect(engine.lastUrl, contains('track2'));
      final urlCountAfterTrack2 = engine.setUrlCallCount;

      // Ahora, tarde, la extracción huérfana de track1 por fin resuelve con
      // éxito. Sin el guard de generación, esto pisaría el motor con la URL
      // de track1 aunque el usuario ya esté en track2.
      held.complete(ExtractionSuccess(
        requestId: 'stale_req',
        streamUrl: 'https://example.com/audio_track1.mp3',
        headers: const {},
      ));
      await firstPlay;
      await pumpEventQueue();

      expect(controller.state.currentIndex, 1, reason: 'no debe volver a track1');
      expect(engine.lastUrl, contains('track2'), reason: 'el motor no debe recibir la URL vieja de track1');
      expect(engine.setUrlCallCount, urlCountAfterTrack2, reason: 'la resolución obsoleta no debe llamar a setUrl de nuevo');
    });
  });
}
