import 'dart:async';

import 'package:just_audio/just_audio.dart';

import 'audio_engine_state.dart';

/// Implementación de [AudioEngine] para **Android** basada en `just_audio`
/// (ExoPlayer internamente).
///
/// Maneja los headers HTTP requeridos por YouTube (Pitfall #13) vía
/// `AudioSource.uri(headers:)` y expone un único [stateStream] unificado.
///
/// El recorte de silencios ([setSkipSilenceEnabled]) activa el flag nativo de
/// ExoPlayer `setSkipSilenceEnabled`, **exclusivamente** para contenido
/// spoken-word/podcasts (Pitfall #7). El gapless entre canciones musicales lo
/// resuelve la Playlist API de ExoPlayer, no este flag.
class JustAudioEngine implements AudioEngine {
  // Ronda 10 (batería): los headers (el User-Agent del cliente, Pitfall #13)
  // los manda ExoPlayer directamente. Con el proxy por defecto, todo el audio
  // pasaba por un servidor HTTP en Dart dentro del isolate principal, que se
  // despertaba con cada trozo durante horas en segundo plano.
  final AudioPlayer _player = AudioPlayer(useProxyForRequestHeaders: false);

  final StreamController<AudioEngineState> _stateController =
      StreamController<AudioEngineState>.broadcast();
  final StreamController<void> _completionController =
      StreamController<void>.broadcast();
  final StreamController<String> _logStreamController =
      StreamController<String>.broadcast();

  AudioEngineState _state = AudioEngineState.initial;

  JustAudioEngine() {
    // playerStateStream entrega (playing, processingState) juntos.
    _player.playerStateStream.listen(_onPlayerState);

    _player.positionStream.listen(_onPosition);
    _player.bufferedPositionStream.listen(_onBuffered);
    _player.durationStream.listen(_onDuration);
    _player.processingStateStream.listen(_onProcessingState);

    // Ronda 10: desde just_audio 0.10 los errores de ExoPlayer ya no llegan
    // como error del stream (este `onError` nunca se dispara): llegan como un
    // evento con `errorCode` y el estado en `idle` (ver `_isErrorIdle`).
    _player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace st) {
        _logStreamController.add('[JustAudio:error] $e');
        _emit(_state.copyWith(processingState: AudioProcessingState.error));
      },
    );
  }

  /// `idle` con `errorCode`: ExoPlayer falló (just_audio 0.10 lo publica así).
  ///
  /// Ronda 10: tratarlo como un `idle` cualquiera era el bug de "pausé unos
  /// minutos y al darle play empezó desde 0": en pausa, YouTube corta la
  /// conexión, ExoPlayer da error y el motor quedaba en `idle` sin que el
  /// controlador lo viera como error. Su `play()` con el motor en `idle`
  /// recarga la pista, y como nadie había guardado la posición, desde 0. De
  /// paso la notificación perdía la barra (`idle` = sin sesión). Como error,
  /// el controlador guarda el segundo y lo retoma (H-R4-2).
  bool _isErrorIdle(ProcessingState s) => s == ProcessingState.idle && _player.playbackEvent.errorCode != null;

  void _emitError() {
    if (_state.processingState != AudioProcessingState.error) {
      final event = _player.playbackEvent;
      _logStreamController.add('[JustAudio:error] ${event.errorCode} ${event.errorMessage ?? ''}');
    }
    _emit(_state.copyWith(playing: false, processingState: AudioProcessingState.error));
  }

  @override
  Stream<AudioEngineState> get stateStream => _stateController.stream;

  @override
  Stream<void> get completionStream => _completionController.stream;

  @override
  Stream<String> get logStream => _logStreamController.stream;

  @override
  Duration get position => _player.position;

  @override
  Duration get duration => _player.duration ?? Duration.zero;

  @override
  Future<void> setUrl(String url, {Map<String, String>? headers, Duration? initialPosition}) async {
    _emit(_state.copyWith(processingState: AudioProcessingState.loading));
    final source = AudioSource.uri(
      Uri.parse(url),
      headers: headers ?? const {},
    );
    await _player.setVolume(_state.volume.clamp(0.0, 1.0));
    await _player.setAudioSource(source, initialPosition: initialPosition);
  }

  @override
  Future<void> setLocalSource(String path, {Duration? initialPosition}) async {
    _emit(_state.copyWith(processingState: AudioProcessingState.loading));
    final source = AudioSource.file(path);
    await _player.setVolume(_state.volume.clamp(0.0, 1.0));
    await _player.setAudioSource(source, initialPosition: initialPosition);
  }


  @override
  Future<void> play() async {
    await _player.setVolume(_state.volume.clamp(0.0, 1.0));
    // `AudioPlayer.play()` de just_audio NO completa cuando la reproducción
    // arranca, sino cuando TERMINA (fin de pista, pausa o stop). Devolver ese
    // future hacía que `await _engine.play()` en el controlador se quedara
    // esperando la canción entera y, como `skipToNext()` mantiene su guard
    // `_isTransitioning` mientras espera, el segundo "siguiente" salía por el
    // guard sin hacer nada: el botón quedaba muerto hasta que la pista acabara
    // (o hasta que otra acción parara el motor y completara este future, que es
    // por qué tocar la barra o poner otra canción lo "revivía").
    //
    // No aplica a Windows: `media_kit` sí retorna en cuanto emite el comando,
    // por eso el fallo solo se veía en Android.
    unawaited(_player.play());
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await _player.setVolume(_state.volume.clamp(0.0, 1.0));
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed.clamp(0.25, 2.0));

  @override
  Future<void> setVolume(double volume) {
    final clamped = volume.clamp(0.0, 1.0);
    _state = _state.copyWith(volume: clamped);
    return _player.setVolume(clamped);
  }

  @override
  Future<void> microFadeOut() async {
    final curVol = _state.volume;
    if (curVol <= 0.0) return;
    try {
      await smoothFadeOut(_player.setVolume, curVol);
      await _player.stop();
      // Restaura el volumen del motor nativo a nivel canónico tras detenerse
      await _player.setVolume(curVol.clamp(0.0, 1.0));
    } catch (_) {}
  }

  @override
  Future<void> setSkipSilenceEnabled(bool enabled) async {
    // ExoPlayer nativo. Solo para spoken-word/podcasts (Pitfall #7); el
    // gapless entre canciones musicales lo resuelve la Playlist API.
    await _player.setSkipSilenceEnabled(enabled);
  }

  /// Fallback SIN fade real (Fase 7.D): esta implementación cruda nunca se
  /// usa directamente para crossfade en producción — [CrossfadeAudioEngine]
  /// envuelve dos instancias de [AudioEngine] (sean cuales sean) y es donde
  /// vive el fade paralelo de verdad. Este método solo existe para que
  /// [JustAudioEngine] siga cumpliendo el contrato [AudioEngine] si algo lo
  /// invoca directo (ej. en tests); equivale a una transición normal.
  @override
  Future<void> crossfadeToLocalSource(String path, Duration duration) async {
    await stop();
    await setLocalSource(path);
    await play();
  }

  // --- Transformadores de eventos nativos -> [AudioEngineState] -----------

  void _onPlayerState(PlayerState s) {
    if (s.processingState == ProcessingState.completed) {
      // Ronda 8 (H-R8-1): solo al ENTRAR en `completed`. `playerStateStream`
      // vuelve a emitir con el mismo estado cuando cambia `playing` (el
      // `stop()` antes de cargar la siguiente lo pone en `false`), y avisar
      // otra vez hacía avanzar dos canciones.
      final enteredCompleted = _state.processingState != AudioProcessingState.completed;
      if (enteredCompleted) _completionController.add(null);
      // ExoPlayer se queda en `completed`; el controlador decidirá el siguiente
      // paso (siguiente pista / repeat one / pausa).
      _emit(_state.copyWith(
        playing: false,
        processingState: AudioProcessingState.completed,
      ));
      return;
    }
    if (_isErrorIdle(s.processingState)) {
      _emitError();
      return;
    }
    _emit(_state.copyWith(
      playing: s.playing,
      processingState: _mapProcessingState(s.processingState),
    ));
  }

  void _onProcessingState(ProcessingState s) {
    if (s == ProcessingState.completed) return; // ya tratado arriba
    if (_isErrorIdle(s)) {
      _emitError();
      return;
    }
    _emit(_state.copyWith(processingState: _mapProcessingState(s)));
  }

  void _onPosition(Duration p) {
    // Tras un error la posición que importa es la última que sonó: es la que
    // el controlador retoma.
    if (_state.processingState == AudioProcessingState.error) return;
    _emit(_state.copyWith(position: p));
  }

  void _onBuffered(Duration b) =>
      _emit(_state.copyWith(bufferedPosition: b));

  void _onDuration(Duration? d) =>
      _emit(_state.copyWith(duration: d ?? Duration.zero));

  AudioProcessingState _mapProcessingState(ProcessingState s) {
    switch (s) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  void _emit(AudioEngineState next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  @override
  void dispose() {
    _stateController.close();
    _completionController.close();
    _logStreamController.close();
    _player.dispose();
  }
}
