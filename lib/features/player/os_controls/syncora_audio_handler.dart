import 'dart:async';
import 'package:audio_service/audio_service.dart';
import '../player_models.dart';
import '../syncora_player_controller.dart';
import '../audio_engine/audio_engine_state.dart' as engine_state;

/// Adaptador de Android para conectar [SyncoraPlayerController] con [audio_service].
///
/// Refleja el estado del controlador en la notificación del sistema y la pantalla
/// de bloqueo, y retransmite las acciones del usuario (play, pause, seek, skip)
/// de vuelta al controlador.
class SyncoraAudioHandler extends BaseAudioHandler with SeekHandler {
  SyncoraPlayerController _controller;

  SyncoraAudioHandler(this._controller) {
    _controller.addListener(_onControllerChanged);
    _onControllerChanged(); // Estado inicial
  }

  /// Actualiza la instancia del controlador cuando el provider se recrea.
  void updateController(SyncoraPlayerController newController) {
    if (_controller == newController) return;
    _controller.removeListener(_onControllerChanged);
    _controller = newController;
    _controller.addListener(_onControllerChanged);
    _onControllerChanged();
  }

  void _onControllerChanged() {
    final state = _controller.state;
    final engineState = state.engine;

    // 1. MediaItem (pista actual)
    final track = state.currentTrack;
    if (track != null) {
      mediaItem.add(_toMediaItem(track));
    } else {
      mediaItem.add(null);
    }

    // 2. Queue
    final queueItems = state.queue.map(_toMediaItem).toList();
    queue.add(queueItems);

    // 3. PlaybackState
    final isPlaying = engineState.playing;
    final controls = <MediaControl>[
      MediaControl.skipToPrevious,
      isPlaying ? MediaControl.pause : MediaControl.play,
      MediaControl.skipToNext,
    ];

    playbackState.add(
      PlaybackState(
        controls: controls,
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: _mapProcessingState(engineState.processingState),
        playing: isPlaying,
        updatePosition: engineState.position,
        bufferedPosition: engineState.bufferedPosition,
        speed: engineState.speed,
        queueIndex: state.currentIndex >= 0 ? state.currentIndex : null,
      ),
    );
  }

  AudioProcessingState _mapProcessingState(engine_state.AudioProcessingState state) {
    switch (state) {
      case engine_state.AudioProcessingState.idle:
        return AudioProcessingState.idle;
      case engine_state.AudioProcessingState.loading:
        return AudioProcessingState.loading;
      case engine_state.AudioProcessingState.buffering:
        return AudioProcessingState.buffering;
      case engine_state.AudioProcessingState.ready:
        return AudioProcessingState.ready;
      case engine_state.AudioProcessingState.completed:
        return AudioProcessingState.completed;
      case engine_state.AudioProcessingState.error:
        return AudioProcessingState.error;
    }
  }

  MediaItem _toMediaItem(SyncoraTrack track) {
    return MediaItem(
      id: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album ?? '',
      duration: track.duration,
      artUri: track.artUri,
    );
  }

  // ----------------------------------------------------------------------
  // Overrides de BaseAudioHandler
  // ----------------------------------------------------------------------

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> stop() => _controller.stop();

  @override
  Future<void> seek(Duration position) => _controller.seek(position);

  @override
  Future<void> skipToNext() => _controller.skipToNext();

  @override
  Future<void> skipToPrevious() => _controller.skipToPrevious();

  @override
  Future<void> skipToQueueItem(int index) => _controller.playIndex(index);

  @override
  Future<void> onTaskRemoved() async {
    await stop();
    await super.onTaskRemoved();
  }
}
