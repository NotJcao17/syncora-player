import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/extraction/extraction_service.dart';
import 'package:syncora_player/core/extraction/models/extraction_request.dart';
import 'package:syncora_player/core/extraction/models/extraction_result.dart';
import 'package:syncora_player/features/player/audio_engine/audio_engine_state.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/syncora_player_controller.dart';

/// Motor que emite sus estados de forma **asíncrona**, como just_audio en
/// Android: `setUrl`/`play` devuelven antes de que el estado correspondiente
/// llegue por el stream.
///
/// El `FakeAudioEngine` del resto de la suite emite de forma síncrona dentro de
/// `setUrl`, y por eso los bugs de orden de eventos del reproductor en Android
/// nunca aparecían en los tests.
class AsyncAudioEngine implements AudioEngine {
  final _stateController = StreamController<AudioEngineState>.broadcast();
  final _completionController = StreamController<void>.broadcast();
  final _logController = StreamController<String>.broadcast();

  AudioEngineState _state = AudioEngineState.initial;
  int setUrlCallCount = 0;
  int playCallCount = 0;

  @override
  Stream<AudioEngineState> get stateStream => _stateController.stream;
  @override
  Stream<void> get completionStream => _completionController.stream;
  @override
  Stream<String> get logStream => _logController.stream;
  @override
  Duration get position => _state.position;
  @override
  Duration get duration => _state.duration;

  void _emitLater(AudioEngineState next) {
    Future.microtask(() {
      _state = next;
      if (!_stateController.isClosed) _stateController.add(next);
    });
  }

  @override
  Future<void> setUrl(String url, {Map<String, String>? headers, Duration? initialPosition}) async {
    setUrlCallCount++;
    _emitLater(_state.copyWith(
      processingState: AudioProcessingState.ready,
      position: initialPosition ?? Duration.zero,
      duration: const Duration(seconds: 180),
    ));
  }

  @override
  Future<void> setLocalSource(String path, {Duration? initialPosition}) async {
    _emitLater(_state.copyWith(
      processingState: AudioProcessingState.ready,
      position: initialPosition ?? Duration.zero,
      duration: const Duration(seconds: 180),
    ));
  }

  @override
  Future<void> play() async {
    playCallCount++;
    _emitLater(_state.copyWith(playing: true, processingState: AudioProcessingState.ready));
  }

  @override
  Future<void> pause() async {
    _emitLater(_state.copyWith(playing: false));
  }

  @override
  Future<void> stop() async {
    _emitLater(_state.copyWith(
      playing: false,
      position: Duration.zero,
      processingState: AudioProcessingState.idle,
    ));
  }

  @override
  Future<void> seek(Duration position) async {
    _emitLater(_state.copyWith(position: position));
  }

  @override
  Future<void> setVolume(double volume) async {
    _emitLater(_state.copyWith(volume: volume));
  }

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> microFadeOut() async {}

  @override
  Future<void> setSkipSilenceEnabled(bool enabled) async {}

  @override
  Future<void> crossfadeToLocalSource(String path, Duration duration) async {}

  @override
  Future<void> dispose() async {
    await _stateController.close();
    await _completionController.close();
    await _logController.close();
  }
}

class _OkExtractionService implements ExtractionService {
  final _logController = StreamController<String>.broadcast();
  int extractCount = 0;

  @override
  Stream<String> get onLogMessage => _logController.stream;

  @override
  void resetEngine() {}

  @override
  Future<ExtractionResult> extractUrl(
    String videoId, {
    String? trackTitle,
    String? trackArtist,
    int? durationSeconds,
    ExtractionPriority priority = ExtractionPriority.streaming,
    String? quality,
  }) async {
    extractCount++;
    // Asíncrono a propósito: la extracción real nunca resuelve en el mismo
    // microtask que la llamada.
    await Future<void>.delayed(Duration.zero);
    return ExtractionSuccess(
      requestId: videoId,
      streamUrl: 'https://example.test/$videoId.m4a',
      headers: const {},
    );
  }

  @override
  void dispose() {
    _logController.close();
  }
}

void main() {
  test('dos "siguiente" seguidos avanzan dos pistas (motor asíncrono, como Android)', () async {
    final engine = AsyncAudioEngine();
    final controller = SyncoraPlayerController(
      engine: engine,
      extractionService: _OkExtractionService(),
    );
    controller.init();

    await controller.setQueue(const [
      SyncoraTrack(id: 't1', title: 'Uno'),
      SyncoraTrack(id: 't2', title: 'Dos'),
      SyncoraTrack(id: 't3', title: 'Tres'),
    ], autoplay: true);
    await pumpEventQueue();

    expect(controller.state.currentTrack?.id, 't1');

    await controller.skipToNext();
    await pumpEventQueue();
    expect(controller.state.currentTrack?.id, 't2',
        reason: 'el primer "siguiente" debe avanzar');

    // El caso reportado: el SEGUNDO "siguiente", sin ninguna otra acción de
    // reproducción entre medio, no hacía nada en Android.
    await controller.skipToNext();
    await pumpEventQueue();
    expect(controller.state.currentTrack?.id, 't3',
        reason: 'el segundo "siguiente" seguido también debe avanzar');

    controller.dispose();
  });
}
