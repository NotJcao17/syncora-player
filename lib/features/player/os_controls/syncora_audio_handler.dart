import 'dart:async';
import 'package:audio_service/audio_service.dart';
import '../../../data/apis/deezer_api.dart';
import '../../../data/local_db/daos/playlist_dao.dart';
import '../../../data/supabase/supabase_playlist_repository.dart';
import '../../library/services/like_track_service.dart';
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
  SupabasePlaylistRepository? _supabaseRepo;
  DeezerApi? _deezerApi;

  // Mismo motivo que el corazón (ver `_favoriteControl`): un `MediaControl`
  // con `action:` sirve para las acciones estándar de transporte, pero un botón
  // propio en la notificación necesita `MediaControl.custom` con `name`, que es
  // lo que enruta el click hacia `customAction()` (ya maneja 'toggleShuffle').
  // Sin eso el botón no llegaba a dibujarse.
  static final MediaControl _shuffleControl = MediaControl.custom(
    androidIcon: 'drawable/ic_shuffle',
    label: 'Shuffle',
    name: 'toggleShuffle',
  );

  // Ítem 4 (QA): el corazón vivía como `MediaControl` FIJO con un único
  // ícono relleno (`ic_heart`) -- por eso se veía "liked" siempre, sin
  // importar el estado real: no había ningún ícono alternativo para el
  // estado "no me gusta" ni lógica que eligiera entre ambos. Ahora se arma
  // dinámicamente en cada publicación de `playbackState` según
  // `_isCurrentTrackLiked` (ver `_favoriteControl` getter y
  // `_publishPlaybackState`).
  //
  // `MediaControl.custom` (no el constructor por defecto con
  // `action: MediaAction.custom`) es obligatorio para acciones custom: sin
  // el `name` que arma su `CustomMediaAction`, el botón nunca llegaba a
  // asociarse con ningún `customAction()` real del handler (el `assert` que
  // lo exige queda mudo en release, así que fallaba en silencio).
  MediaControl get _favoriteControl => MediaControl.custom(
        androidIcon: _isCurrentTrackLiked ? 'drawable/ic_heart' : 'drawable/ic_heart_outline',
        label: _isCurrentTrackLiked ? 'Quitar de Me gusta' : 'Me gusta',
        name: 'toggleFavorite',
      );

  /// Estado "me gusta" de [_likedStateTrackId] (la última pista para la que
  /// se consultó/actualizó). Ítem 4 (QA): sin esto el corazón quedaba
  /// pegado al valor de construcción para siempre -- ver
  /// `_refreshLikedState`/`_toggleFavorite`.
  bool _isCurrentTrackLiked = false;
  String? _likedStateTrackId;

  SyncoraAudioHandler(
    this._controller, {
    PlaylistDao? playlistDao,
    SupabasePlaylistRepository? supabaseRepo,
    DeezerApi? deezerApi,
  })  : _playlistDao = playlistDao, // ignore: prefer_initializing_formals
        _supabaseRepo = supabaseRepo, // ignore: prefer_initializing_formals
        _deezerApi = deezerApi { // ignore: prefer_initializing_formals
    _controller.addListener(_onControllerChanged);
    _onControllerChanged(); // Estado inicial
  }

  /// Actualiza la instancia del controlador cuando el provider se recrea.
  void updateController(
    SyncoraPlayerController newController, {
    PlaylistDao? playlistDao,
    SupabasePlaylistRepository? supabaseRepo,
    DeezerApi? deezerApi,
  }) {
    if (playlistDao != null) _playlistDao = playlistDao;
    if (supabaseRepo != null) _supabaseRepo = supabaseRepo;
    if (deezerApi != null) _deezerApi = deezerApi;
    if (_controller == newController) return;
    _controller.removeListener(_onControllerChanged);
    _controller = newController;
    _controller.addListener(_onControllerChanged);
    _onControllerChanged();
  }

  void _onControllerChanged() {
    final state = _controller.state;

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

    // Ítem 4 (QA): la pista activa cambió -- el flag de "me gusta" quedado
    // de la anterior ya no representa nada real, hay que refrescarlo contra
    // la DB antes de volver a publicar el corazón (async, ver
    // `_refreshLikedState`). Comparar por id evita relanzar la consulta en
    // cada tick de posición (este método corre en CADA cambio del
    // controller, no solo al cambiar de pista).
    if (track?.id != _likedStateTrackId) {
      _refreshLikedState(track);
    }

    _publishPlaybackState();
  }

  /// Publica el `playbackState` completo con los controles vigentes --
  /// factorizado fuera de [_onControllerChanged] (ítem 4, QA) porque
  /// [_toggleFavorite] y [_refreshLikedState] también necesitan re-publicar
  /// tras actualizar [_isCurrentTrackLiked] SIN esperar a que el controller
  /// dispare su propio `ChangeNotifier` (que nunca lo hace: el estado de "me
  /// gusta" vive en la DB de playlists, no en `SyncoraPlayerState`) -- antes
  /// de este fix, tocar el corazón nunca refrescaba la notificación/
  /// lockscreen con el nuevo estado.
  void _publishPlaybackState() {
    final state = _controller.state;
    final engineState = state.engine;
    final track = state.currentTrack;
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

  /// Consulta el estado real de "me gusta" de [track] contra la DB y
  /// re-publica el `playbackState` con el ícono correcto. `null` (nada
  /// sonando) limpia el flag sin consultar nada.
  Future<void> _refreshLikedState(SyncoraTrack? track) async {
    _likedStateTrackId = track?.id;
    final playlistDao = _playlistDao;
    if (track == null || playlistDao == null) {
      _isCurrentTrackLiked = false;
      _publishPlaybackState();
      return;
    }
    final trackIdInt = int.tryParse(track.id) ?? track.id.hashCode.abs();
    bool liked;
    try {
      liked = await playlistDao.isTrackLiked(trackIdInt);
    } catch (_) {
      liked = false;
    }
    // La pista pudo haber cambiado de nuevo mientras esta consulta estaba en
    // vuelo -- si ya no es la vigente, esta respuesta quedó obsoleta y no
    // debe pisar el estado de una pista más nueva.
    if (_likedStateTrackId != track.id) return;
    _isCurrentTrackLiked = liked;
    _publishPlaybackState();
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
    final playlistDao = _playlistDao;
    if (track == null || playlistDao == null) return;
    // Vía el servicio compartido: sube también a Supabase. Antes escribía solo
    // en Drift y el "me gusta" desde la pantalla de bloqueo se revertía al
    // recargar la biblioteca.
    final repo = _supabaseRepo;
    final api = _deezerApi;
    if (repo == null || api == null) return;
    final result = await toggleTrackLikeWith(
      dao: playlistDao,
      supabaseRepo: repo,
      deezerApi: api,
      track: track,
    );
    final nowLiked = result.isLiked;
    // Ítem 4 (QA): sin esto el corazón nunca reflejaba el toggle -- nada más
    // dispara una republicación de `playbackState` tras esta acción (ver
    // docstring de `_publishPlaybackState`).
    if (_controller.state.currentTrack?.id == track.id) {
      _isCurrentTrackLiked = nowLiked;
      _likedStateTrackId = track.id;
      _publishPlaybackState();
    }
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
