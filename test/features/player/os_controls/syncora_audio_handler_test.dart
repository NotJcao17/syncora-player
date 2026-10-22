import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/extraction/extraction_service.dart';
import 'package:syncora_player/core/extraction/models/extraction_request.dart';
import 'package:syncora_player/core/extraction/models/extraction_result.dart';
import 'package:syncora_player/features/player/audio_engine/audio_engine_state.dart';
import 'package:syncora_player/features/player/os_controls/syncora_audio_handler.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/syncora_player_controller.dart';

/// Ronda 3, A2 (hallazgo H-R3-2).
///
/// Entre pista y pista el controlador llama a `_engine.stop()` y el motor
/// emite `idle`. `audio_service` interpreta `idle` como "ya no hay sesion de
/// reproduccion" y **destruye la notificacion, soltando el foreground
/// service**. Eso explicaba dos sintomas distintos de las pruebas en Android:
/// el reproductor de la pantalla de bloqueo parpadeando en cada cambio de
/// pista, y los varios minutos de silencio con la pantalla apagada (sin FGS
/// vivo el sistema congela el proceso justo mientras se extrae la URL
/// siguiente).
///
/// Lo que se fija aqui: durante una transicion con pista activa, al SO nunca
/// se le publica `idle`.
class _SlowEngine implements AudioEngine {
  final _stateController = StreamController<AudioEngineState>.broadcast();
  final _completionController = StreamController<void>.broadcast();
  final _logController = StreamController<String>.broadcast();

  AudioEngineState _state = AudioEngineState.initial;

  /// Compuerta que sostiene la carga: mientras no se complete, el controlador
  /// sigue "preparando" la pista -- que es exactamente la ventana a probar.
  /// `null` = la carga resuelve al instante.
  Completer<void>? loadGate;

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

  void _emit(AudioEngineState s) {
    _state = s;
    _stateController.add(s);
  }

  @override
  Future<void> stop() async {
    // Es justo esta emision la que hacia desaparecer la notificacion.
    _emit(_state.copyWith(processingState: AudioProcessingState.idle, playing: false));
  }

  @override
  Future<void> setUrl(String url, {Map<String, String>? headers, Duration? initialPosition}) async {
    _emit(_state.copyWith(processingState: AudioProcessingState.loading));
    final gate = loadGate;
    if (gate != null) await gate.future;
    _emit(_state.copyWith(
      processingState: AudioProcessingState.ready,
      duration: const Duration(seconds: 180),
    ));
  }

  @override
  Future<void> setLocalSource(String path, {Duration? initialPosition}) async {}
  @override
  Future<void> play() async => _emit(_state.copyWith(playing: true));
  @override
  Future<void> pause() async => _emit(_state.copyWith(playing: false));
  @override
  Future<void> seek(Duration position) async => _emit(_state.copyWith(position: position));
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> setVolume(double volume) async {}
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

class _OkExtraction implements ExtractionService {
  @override
  Stream<String> get onLogMessage => const Stream.empty();

  @override
  Future<ExtractionResult> extractUrl(
    String videoId, {
    String? trackTitle,
    String? trackArtist,
    int? durationSeconds,
    ExtractionPriority priority = ExtractionPriority.streaming,
    String? quality,
  }) async {
    return const ExtractionSuccess(
      requestId: 'test',
      streamUrl: 'https://example.test/a.m4a',
      headers: {},
    );
  }

  @override
  void resetEngine() {}

  @override
  void dispose() {}
}

void main() {
  test('al pasar de una pista a la siguiente nunca se publica idle al SO', () async {
    // Este es el escenario exacto del reporte: ya hay una pista sonando (y por
    // tanto una notificacion viva en la pantalla de bloqueo) y se pulsa
    // "siguiente". El `stop()` del camino de reproduccion emite `idle`.
    final engine = _SlowEngine();
    final controller = SyncoraPlayerController(
      engine: engine,
      extractionService: _OkExtraction(),
    );
    controller.init();
    await pumpEventQueue();

    final handler = SyncoraAudioHandler(controller);

    await controller.setQueue(const [
      SyncoraTrack(id: '1', title: 'A'),
      SyncoraTrack(id: '2', title: 'B'),
    ]);
    await pumpEventQueue();
    expect(handler.playbackState.value.processingState, audio_service.AudioProcessingState.ready);

    // A partir de aqui se captura todo lo que se le publica al SO.
    final publicados = <audio_service.AudioProcessingState>[];
    final sub = handler.playbackState.listen((s) => publicados.add(s.processingState));

    // La carga de la pista siguiente queda colgada: es justo la ventana en la
    // que el motor ya emitio `idle` por el `stop()` y todavia no hay fuente.
    engine.loadGate = Completer<void>();
    unawaited(controller.skipToNext());
    await pumpEventQueue();

    expect(controller.isPreparingPlayback, isTrue);
    expect(
      publicados.contains(audio_service.AudioProcessingState.idle),
      isFalse,
      reason: 'un idle aqui hace que audio_service destruya la notificacion '
          'y suelte el foreground service',
    );
    expect(publicados, contains(audio_service.AudioProcessingState.loading));

    engine.loadGate!.complete();
    await pumpEventQueue();

    expect(controller.isPreparingPlayback, isFalse);
    expect(handler.playbackState.value.processingState, audio_service.AudioProcessingState.ready);

    await sub.cancel();
    controller.dispose();
  });

  test('sin pista activa, idle se sigue publicando tal cual', () async {
    // La traduccion idle -> loading solo aplica mientras hay algo que
    // preparar. Parar del todo debe seguir cerrando la sesion del SO.
    final engine = _SlowEngine();
    final controller = SyncoraPlayerController(
      engine: engine,
      extractionService: _OkExtraction(),
    );
    controller.init();
    await pumpEventQueue();

    final handler = SyncoraAudioHandler(controller);
    await controller.stop();
    await pumpEventQueue();

    expect(handler.playbackState.value.processingState, audio_service.AudioProcessingState.idle);
    controller.dispose();
  });

  // Ronda 10 (batería): con la app en segundo plano se republicaba al SO la
  // sesión entera (pista, cola completa y estado) en cada tick de posición.
  test('los ticks de posición no se republican al SO; play, pausa y saltos sí', () async {
    final engine = _SlowEngine();
    final controller = SyncoraPlayerController(
      engine: engine,
      extractionService: _OkExtraction(),
    );
    controller.init();
    await pumpEventQueue();
    final handler = SyncoraAudioHandler(controller);
    await controller.setQueue([
      for (var i = 0; i < 300; i++) SyncoraTrack(id: '$i', title: 'T$i'),
    ]);
    await pumpEventQueue();

    var states = 0, queues = 0, items = 0;
    final subs = [
      handler.playbackState.skip(1).listen((_) => states++),
      handler.queue.skip(1).listen((_) => queues++),
      handler.mediaItem.skip(1).listen((_) => items++),
    ];

    // Ticks como los del motor real: la posición avanza al ritmo del reloj,
    // espaciados más que el agrupado de 250 ms del controlador.
    final clock = Stopwatch()..start();
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 260));
      engine._emit(engine._state.copyWith(position: clock.elapsed));
    }
    await pumpEventQueue();
    expect(states, 0, reason: 'Android extrapola la posición solo');
    expect(queues, 0);
    expect(items, 0);

    await controller.seek(const Duration(seconds: 90));
    await pumpEventQueue();
    expect(states, 1, reason: 'un salto sí se publica');
    expect(handler.playbackState.value.updatePosition, const Duration(seconds: 90));

    await controller.pause();
    await pumpEventQueue();
    expect(states, 2);
    expect(handler.playbackState.value.playing, isFalse);

    await controller.skipToNext();
    await pumpEventQueue();
    expect(items, greaterThanOrEqualTo(1));
    expect(queues, greaterThanOrEqualTo(1));
    expect(handler.mediaItem.value?.id, '1');

    for (final s in subs) {
      await s.cancel();
    }
    controller.dispose();
  });
}
