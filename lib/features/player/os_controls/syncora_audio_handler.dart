import 'dart:async';
import 'package:audio_service/audio_service.dart';
import '../../../data/local_db/daos/playlist_dao.dart';
import '../player_models.dart';
import '../syncora_player_controller.dart';
import '../audio_engine/audio_engine_state.dart' as engine_state;

/// Adaptador de Android para conectar [SyncoraPlayerController] con [audio_service].
///
/// Refleja el estado del controlador en la notificación del sistema y la pantalla
/// de bloqueo, y retransmite las acciones del usuario (play, pause, seek, skip,
/// shuffle, like) de vuelta al controlador y base de datos.
class SyncoraAudioHandler extends BaseAudioHandler with SeekHandler {
  SyncoraPlayerController _controller;
  PlaylistDao? _playlistDao;

  static const MediaControl _shuffleControl = MediaControl(
    androidIcon: 'drawable/ic_shuffle',
    label: 'Shuffle',
    action: MediaAction.setShuffleMode,
  );

  static const MediaControl _favoriteControl = MediaControl(
    androidIcon: 'drawable/ic_heart',
    label: 'Favorite',
    action: MediaAction.custom,
  );

  SyncoraAudioHandler(this._controller, {PlaylistDao? playlistDao}) : _playlistDao = playlistDao {
    _controller.addListener(_onControllerChanged);
    _onControllerChanged(); // Estado inicial
  }

  /// Actualiza la instancia del controlador cuando el provider se recrea.
  void updateController(SyncoraPlayerController newController, {PlaylistDao? playlistDao}) {
    if (playlistDao != null) _playlistDao = playlistDao;
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

    // 2. Queue: vista combinada de solo-lectura para el SO (Fase 7.A —
    // modelo dual). El índice 0 siempre es la pista actual; luego la manual
    // completa, luego la automática.
    final combinedQueue = <SyncoraTrack>[
      ?track,
      ...state.manualQueue,
      ...state.autoQueue,
    ];
    final queueItems = combinedQueue.map(_toMediaItem).toList();
    queue.add(queueItems);

    // 3. PlaybackState con controles completos
    final isPlaying = engineState.playing;
    final controls = <MediaControl>[
      _shuffleControl,
      MediaControl.skipToPrevious,
      isPlaying ? MediaControl.pause : MediaControl.play,
      MediaControl.skipToNext,
      _favoriteControl,
    ];

    playbackState.add(
      PlaybackState(
        controls: controls,
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.setShuffleMode,
          MediaAction.setRepeatMode,
          MediaAction.custom,
        },
        androidCompactActionIndices: const [1, 2, 3],
        shuffleMode: state.isShuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
        repeatMode: _mapRepeatMode(state.repeatMode),
        processingState: _mapProcessingState(engineState.processingState),
        playing: isPlaying,
        updatePosition: engineState.position,
        bufferedPosition: engineState.bufferedPosition,
        speed: engineState.speed,
        queueIndex: track != null ? 0 : null,
      ),
    );
  }

  AudioServiceRepeatMode _mapRepeatMode(SyncoraRepeatMode mode) {
    switch (mode) {
      case SyncoraRepeatMode.off:
        return AudioServiceRepeatMode.none;
      case SyncoraRepeatMode.all:
        return AudioServiceRepeatMode.all;
      case SyncoraRepeatMode.one:
        return AudioServiceRepeatMode.one;
    }
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
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    _controller.toggleShuffle();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _controller.cycleRepeatMode();
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'toggleFavorite' || name == 'Favorite' || name == 'favorite') {
      await _toggleFavorite();
      return true;
    } else if (name == 'toggleShuffle' || name == 'Shuffle' || name == 'shuffle') {
      _controller.toggleShuffle();
      return true;
    }
    return super.customAction(name, extras);
  }

  Future<void> _toggleFavorite() async {
    final track = _controller.state.currentTrack;
    if (track == null || _playlistDao == null) return;
    final trackIdInt = int.tryParse(track.id) ?? track.id.hashCode.abs();
    await _playlistDao?.toggleLikeTrack(
      trackId: trackIdInt,
      artistId: track.artistId ?? 0,
      albumId: track.albumId ?? 0,
      title: track.title,
      artistName: track.artist,
      albumName: track.album ?? '',
      coverUrl: track.coverUrl,
      durationMs: (track.duration ?? Duration.zero).inMilliseconds,
    );
  }

  /// Traduce un índice de la vista combinada expuesta al SO (ver
  /// [_onControllerChanged]) a `(origen, índice dentro de esa cola)`.
  /// Devuelve `null` si el índice no corresponde a ninguna pista real de las
  /// colas (ej. cae en la posición reservada a la pista actual cuando SÍ hay
  /// una sonando, o queda fuera de rango).
  ///
  /// P1.7 (bug corregido): la vista combinada solo antepone `currentTrack`
  /// cuando `state.currentTrack != null` (ver [_onControllerChanged]) — la
  /// traducción anterior asumía SIEMPRE que el índice 0 era la actual, sin
  /// importar si de verdad había algo sonando, produciendo un offset
  /// corrido en 1 cuando `currentTrack` era `null`. Esta función comparte la
  /// MISMA condición (`hasCurrent`) que arma la lista, para que construcción
  /// y traducción nunca diverjan (P2.1).
  (QueueOrigin, int)? _resolveCombinedIndex(int index) {
    final state = _controller.state;
    final hasCurrent = state.currentTrack != null;
    if (hasCurrent && index <= 0) return null; // 0 es la actual, no-op
    final offset = hasCurrent ? index - 1 : index;
    if (offset < 0) return null;
    final manualLength = state.manualQueue.length;
    if (offset < manualLength) return (QueueOrigin.manual, offset);
    return (QueueOrigin.auto, offset - manualLength);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    final resolved = _resolveCombinedIndex(index);
    if (resolved == null) return;
    await _controller.playFromQueue(resolved.$1, resolved.$2);
  }

  @override
  Future<void> onTaskRemoved() async {
    await stop();
    await super.onTaskRemoved();
  }
}
