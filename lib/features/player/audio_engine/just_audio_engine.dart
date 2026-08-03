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
  final AudioPlayer _player = AudioPlayer();

  final StreamController<AudioEngineState> _stateController =
      StreamController<AudioEngineState>.broadcast();
  final StreamController<void> _completionController =
      StreamController<void>.broadcast();

  AudioEngineState _state = AudioEngineState.initial;

  JustAudioEngine() {
    // playerStateStream entrega (playing, processingState) juntos.
    _player.playerStateStream.listen(_onPlayerState);

    _player.positionStream.listen(_onPosition);
    _player.bufferedPositionStream.listen(_onBuffered);
    _player.durationStream.listen(_onDuration);
    _player.processingStateStream.listen(_onProcessingState);

    _player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace st) {
        _emit(_state.copyWith(processingState: AudioProcessingState.error));
      },
    );
  }

  @override
  Stream<AudioEngineState> get stateStream => _stateController.stream;

  @override
  Stream<void> get completionStream => _completionController.stream;

  @override
  Duration get position => _player.position;

  @override
  Duration get duration => _player.duration ?? Duration.zero;

  @override
  Future<void> setUrl(String url, {Map<String, String>? headers}) async {
    _emit(_state.copyWith(processingState: AudioProcessingState.loading));
    final source = AudioSource.uri(
      Uri.parse(url),
      headers: headers ?? const {},
    );
    await _player.setAudioSource(source);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> setSkipSilenceEnabled(bool enabled) async {
    // ExoPlayer nativo. Solo para spoken-word/podcasts (Pitfall #7); el
    // gapless entre canciones musicales lo resuelve la Playlist API.
    await _player.setSkipSilenceEnabled(enabled);
  }

  // --- Transformadores de eventos nativos -> [AudioEngineState] -----------

  void _onPlayerState(PlayerState s) {
    // notificación de completado.
    if (s.processingState == ProcessingState.completed) {
      _completionController.add(null);
      // ExoPlayer se queda en `completed`; el controlador decidirá el siguiente
      // paso (siguiente pista / repeat one / pausa).
      _emit(_state.copyWith(
        playing: false,
        processingState: AudioProcessingState.completed,
      ));
      return;
    }
    _emit(_state.copyWith(
      playing: s.playing,
      processingState: _mapProcessingState(s.processingState),
    ));
  }

  void _onProcessingState(ProcessingState s) {
    if (s == ProcessingState.completed) return; // ya tratado arriba
    _emit(_state.copyWith(processingState: _mapProcessingState(s)));
  }

  void _onPosition(Duration p) =>
      _emit(_state.copyWith(position: p));

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
    _player.dispose();
  }
}
