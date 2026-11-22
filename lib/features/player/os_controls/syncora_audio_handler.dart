import 'dart:async';
import 'dart:math' as math;
import 'package:audio_service/audio_service.dart';
import '../../../data/apis/deezer_api.dart';
import '../../../data/local_db/daos/folder_dao.dart';
import '../../../data/local_db/daos/playlist_dao.dart';
import '../../../data/local_db/daos/saved_album_dao.dart';
import '../../../data/supabase/supabase_playlist_repository.dart';
import '../../library/services/like_track_service.dart';
import '../player_models.dart';
import '../radio/radio_service.dart';
import 'android_auto_browser.dart';
import 'home_widgets.dart';
import '../syncora_player_controller.dart';
import '../audio_engine/audio_engine_state.dart' as engine_state;
import '../../../data/local_db/daos/downloaded_track_dao.dart';

/// Adaptador de Android para conectar [SyncoraPlayerController] con [audio_service].
///
/// Refleja el estado del controlador en la notificación del sistema y la pantalla
/// de bloqueo, y retransmite las acciones del usuario (play, pause, seek, skip,
/// shuffle, like) de vuelta al controlador y base de datos.
class SyncoraAudioHandler extends BaseAudioHandler with SeekHandler {
  SyncoraPlayerController _controller;
  PlaylistDao? _playlistDao;
  DownloadedTrackDao? _downloadedTrackDao;
  SavedAlbumDao? _savedAlbumDao;
  FolderDao? _folderDao;
  SupabasePlaylistRepository? _supabaseRepo;
  DeezerApi? _deezerApi;

  /// `canEditProvider` (modo local || con conexión). Sin esto, el corazón de
  /// la pantalla de bloqueo escribía en Drift estando offline y el siguiente
  /// sync podaba el cambio (Pitfall #28). Acá no hay botón que deshabilitar
  /// con el patrón visual de la app, así que la acción simplemente no se
  /// ejecuta y se avisa por `PlayerNotice`.
  bool Function()? _canEditGetter;

  // Mismo motivo que el corazón (ver `_favoriteControl`): un `MediaControl`
  // con `action:` sirve para las acciones estándar de transporte, pero un botón
  // propio en la notificación necesita `MediaControl.custom` con `name`, que es
  // lo que enruta el click hacia `customAction()` (ya maneja 'toggleShuffle').
  // Sin eso el botón no llegaba a dibujarse.
  // Ronda 3 (A6): antes era una constante con `ic_shuffle` fijo, así que el
  // botón se veía idéntico con aleatorio activado o apagado y no había forma
  // de saber el modo desde la pantalla de bloqueo. Ahora alterna entre dos
  // drawables, exactamente el mismo patrón que ya usa `_favoriteControl`
  // para el corazón.
  MediaControl get _shuffleControl => MediaControl.custom(
        androidIcon: _controller.state.isShuffle
            ? 'drawable/ic_shuffle'
            : 'drawable/ic_shuffle_off',
        label: _controller.state.isShuffle
            ? 'Aleatorio activado'
            : 'Aleatorio desactivado',
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
    bool Function()? canEditGetter,
    DownloadedTrackDao? downloadedTrackDao,
    SavedAlbumDao? savedAlbumDao,
    FolderDao? folderDao,
  })  : _playlistDao = playlistDao, // ignore: prefer_initializing_formals
        _downloadedTrackDao = downloadedTrackDao, // ignore: prefer_initializing_formals
        _savedAlbumDao = savedAlbumDao, // ignore: prefer_initializing_formals
        _folderDao = folderDao, // ignore: prefer_initializing_formals
        _supabaseRepo = supabaseRepo, // ignore: prefer_initializing_formals
        _deezerApi = deezerApi, // ignore: prefer_initializing_formals
        _canEditGetter = canEditGetter { // ignore: prefer_initializing_formals
    _controller.addListener(_onControllerChanged);
    _onControllerChanged(); // Estado inicial
  }

  /// Actualiza la instancia del controlador cuando el provider se recrea.
  void updateController(
    SyncoraPlayerController newController, {
    PlaylistDao? playlistDao,
    SupabasePlaylistRepository? supabaseRepo,
    DeezerApi? deezerApi,
    bool Function()? canEditGetter,
    DownloadedTrackDao? downloadedTrackDao,
    SavedAlbumDao? savedAlbumDao,
    FolderDao? folderDao,
  }) {
    if (playlistDao != null) _playlistDao = playlistDao;
    if (downloadedTrackDao != null) _downloadedTrackDao = downloadedTrackDao;
    if (savedAlbumDao != null) _savedAlbumDao = savedAlbumDao;
    if (folderDao != null) _folderDao = folderDao;
    _autoBrowser = null;
    if (supabaseRepo != null) _supabaseRepo = supabaseRepo;
    if (deezerApi != null) _deezerApi = deezerApi;
    if (canEditGetter != null) _canEditGetter = canEditGetter;
    if (_controller == newController) return;
    _controller.removeListener(_onControllerChanged);
    _controller = newController;
    _controller.addListener(_onControllerChanged);
    _forceNextPublish = true;
    _onControllerChanged();
  }

  // Ronda 10 (batería): el controlador notifica unas 4 veces por segundo
  // mientras suena (la posición), y cada vez se le volvía a mandar al SO la
  // pista, la cola completa (cientos de canciones serializadas por el canal
  // de plataforma) y el estado. En el teléfono se veía la sesión
  // republicada cada ~400 ms durante horas en segundo plano. Android calcula
  // solo la posición a partir de la última publicación (`updateTime` +
  // velocidad), así que basta publicar cuando algo cambia de verdad.
  bool _forceNextPublish = true;
  SyncoraTrack? _publishedTrack;
  List<SyncoraTrack>? _publishedManualQueue;
  List<SyncoraTrack>? _publishedAutoQueue;
  PlaybackState? _lastPublishedState;
  String? _lastPublishedControlsKey;

  /// Más que esto entre la posición real y la que Android extrapola es un
  /// salto (seek), y hay que publicarlo.
  static const Duration _positionDriftTolerance = Duration(seconds: 2);

  void _onControllerChanged() {
    final state = _controller.state;
    final force = _forceNextPublish;
    _forceNextPublish = false;

    // 1. MediaItem (pista actual). Las listas y pistas del estado son
    // inmutables y solo se reemplazan al cambiar: comparar identidad basta.
    final track = state.currentTrack;
    final trackChanged = force || !identical(track, _publishedTrack);
    if (trackChanged) {
      mediaItem.add(track == null ? null : _toMediaItem(track));
    }

    // 2. Queue: vista combinada de solo-lectura para el SO (Fase 7.A —
    // modelo dual). El índice 0 siempre es la pista actual; luego la manual
    // completa, luego la automática.
    if (trackChanged ||
        !identical(state.manualQueue, _publishedManualQueue) ||
        !identical(state.autoQueue, _publishedAutoQueue)) {
      final combinedQueue = <SyncoraTrack>[
        ?track,
        ...state.manualQueue,
        ...state.autoQueue,
      ];
      queue.add(combinedQueue.map(_toQueueItem).toList());
      _publishedManualQueue = state.manualQueue;
      _publishedAutoQueue = state.autoQueue;
    }
    _publishedTrack = track;

    // Ítem 4 (QA): la pista activa cambió -- el flag de "me gusta" quedado
    // de la anterior ya no representa nada real, hay que refrescarlo contra
    // la DB antes de volver a publicar el corazón (async, ver
    // `_refreshLikedState`). Comparar por id evita relanzar la consulta en
    // cada tick de posición (este método corre en CADA cambio del
    // controller, no solo al cambiar de pista).
    if (track?.id != _likedStateTrackId) {
      _refreshLikedState(track);
    }

    _publishPlaybackState(force: trackChanged);

    // Ronda 13: widget "Reproduciendo" (solo publica si cambió algo). Entre
    // pista y pista el motor pausa un instante: contarlo como "sonando" evita
    // que el botón del widget parpadee.
    widgetPublisher?.onState(NowPlayingWidgetState.of(
      track,
      playing: state.engine.playing || (_controller.isPreparingPlayback && track != null),
    ));
  }

  /// Lo asigna `player_providers.dart` cuando `audio_service` ya está listo.
  NowPlayingWidgetPublisher? _widgetPublisher;
  NowPlayingWidgetPublisher? get widgetPublisher => _widgetPublisher;
  set widgetPublisher(NowPlayingWidgetPublisher? value) {
    _widgetPublisher = value;
    _onControllerChanged();
  }

  /// Publica el `playbackState` completo con los controles vigentes --
  /// factorizado fuera de [_onControllerChanged] (ítem 4, QA) porque
  /// [_toggleFavorite] y [_refreshLikedState] también necesitan re-publicar
  /// tras actualizar [_isCurrentTrackLiked] SIN esperar a que el controller
  /// dispare su propio `ChangeNotifier` (que nunca lo hace: el estado de "me
  /// gusta" vive en la DB de playlists, no en `SyncoraPlayerState`) -- antes
  /// de este fix, tocar el corazón nunca refrescaba la notificación/
  /// lockscreen con el nuevo estado.
  void _publishPlaybackState({bool force = false}) {
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

    final next = PlaybackState(
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
      // Ronda 10: tras un error del motor en pausa la pista sigue en pausa
      // (play la retoma en el mismo segundo). Publicar `idle`/`error` le
      // quitaba la barra a la notificación, como si la sesión hubiera
      // terminado.
      processingState: _controller.isPausedAfterEngineError
          ? AudioProcessingState.ready
          : _mapProcessingState(
              engineState.processingState,
              isPreparing: _controller.isPreparingPlayback && track != null,
            ),
      playing: isPlaying,
      updatePosition: engineState.position,
      bufferedPosition: engineState.bufferedPosition,
      speed: engineState.speed,
      queueIndex: track != null ? 0 : null,
    );
    final controlsKey = '${state.isShuffle}|$_isCurrentTrackLiked';
    final last = _lastPublishedState;
    if (!force &&
        last != null &&
        controlsKey == _lastPublishedControlsKey &&
        _sameExceptPosition(last, next) &&
        !_positionJumped(last, next)) {
      return;
    }
    _lastPublishedState = next;
    _lastPublishedControlsKey = controlsKey;
    playbackState.add(next);
  }

  static bool _sameExceptPosition(PlaybackState a, PlaybackState b) =>
      a.processingState == b.processingState &&
      a.playing == b.playing &&
      a.speed == b.speed &&
      a.shuffleMode == b.shuffleMode &&
      a.repeatMode == b.repeatMode &&
      a.queueIndex == b.queueIndex;

  /// ¿La posición real se apartó de la que Android calcula por su cuenta?
  static bool _positionJumped(PlaybackState last, PlaybackState next) {
    var expected = last.updatePosition;
    if (last.playing) {
      final elapsed = next.updateTime.difference(last.updateTime);
      expected += elapsed * last.speed;
    }
    return (next.updatePosition - expected).abs() > _positionDriftTolerance;
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

  /// Traduce el estado del motor al de `audio_service`.
  ///
  /// Ronda 3 (H-R3-2): [isPreparing] existe por un motivo muy concreto. Entre
  /// pista y pista, el camino de reproducción del controlador llama a
  /// `_engine.stop()` antes de cargar la fuente nueva, y el motor emite
  /// `idle`. `audio_service` interpreta `idle` como "ya no hay sesión de
  /// reproducción" y **destruye la notificación, soltando el foreground
  /// service**. De ahí salían dos síntomas de las pruebas en Android que
  /// parecían independientes: el reproductor de la pantalla de bloqueo
  /// desapareciendo un segundo en cada cambio de pista, y los varios minutos
  /// de silencio con la pantalla apagada (sin FGS vivo el sistema congela el
  /// proceso justo mientras se está extrayendo la URL de la pista
  /// siguiente).
  ///
  /// Publicar `loading` en esa ventana es además lo semánticamente correcto:
  /// hay una pista activa y se está preparando. El estado que ve la **UI**
  /// de la app no cambia — esto solo afecta a lo que se le publica al SO.
  ///
  /// ## Limitación conocida (revisión de la ronda 3, P2)
  ///
  /// `setQueue` y `_advanceAndPlay` notifican **antes** de que la ventana se
  /// abra (`isPreparingPlayback` todavía es `false` en ese `_notify()`). En el
  /// caso normal eso es inofensivo: el motor aún reporta el snapshot
  /// `ready`/`playing` de la pista anterior, así que no se publica `idle`. El
  /// hueco queda cuando el motor **ya estaba en `idle`** al asignarse la pista
  /// nueva (justo tras un `_failPlaybackLoad`, tras un `stop()` explícito, o
  /// en un arranque en frío): ahí se publica un `idle` con pista activa
  /// durante un tick antes de que la ventana se abra.
  ///
  /// No se cierra a propósito. Hacerlo exigiría abrir la ventana desde
  /// `setQueue`/`_advanceAndPlay` adivinando la generación que tomará
  /// `_playCurrentInternal` — una bandera acoplada a un detalle interno y con
  /// un dueño difuso, justo lo que prohíbe §2.3 de
  /// `correcciones_qa_post_fase_7.md`. El coste del hueco es un parpadeo de
  /// notificación en un caso que además arranca desde "no había nada
  /// sonando"; el coste del arreglo es una bandera que se puede quedar
  /// pegada.
  AudioProcessingState _mapProcessingState(
    engine_state.AudioProcessingState state, {
    bool isPreparing = false,
  }) {
    switch (state) {
      case engine_state.AudioProcessingState.idle:
        return isPreparing ? AudioProcessingState.loading : AudioProcessingState.idle;
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

  /// La cola la dibuja Android Auto: con la URL de Deezer no carga la portada
  /// (ver [AutoArt]). La pista actual sí se publica con la URL, porque
  /// `audio_service` la descarga él mismo para la notificación.
  MediaItem _toQueueItem(SyncoraTrack track) => _toMediaItem(track).copyWith(artUri: AutoArt.ofUri(track.artUri));

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
    // Online-First: sin conexión la escritura solo llegaría a Drift y el
    // sync la podaría. Mejor no hacer nada y avisar.
    if (_canEditGetter?.call() == false) {
      _controller.notifyActionBlockedOffline(
        'Sin conexión. No se puede modificar Tus me gusta offline.',
      );
      return;
    }
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

  // ----------------------------------------------------------------------
  // Android Auto: árbol de navegación del `MediaBrowserService`
  // ----------------------------------------------------------------------
  //
  // Ronda 5 lo armó plano (cuatro carpetas sin portadas). Ronda 13: pestañas
  // Inicio / Biblioteca / Descargas con portadas, "Reproducir en aleatorio"
  // y búsqueda; vive en [AndroidAutoBrowser].

  List<SyncoraTrack> _lastSearch = const [];

  AndroidAutoBrowser? get _browser {
    final dao = _playlistDao;
    if (dao == null) return null;
    final current = _autoBrowser;
    if (current != null && identical(current.playlistDao, dao)) return current;
    return _autoBrowser = AndroidAutoBrowser(
      playlistDao: dao,
      savedAlbumDao: _savedAlbumDao,
      folderDao: _folderDao,
      downloadedTrackDao: _downloadedTrackDao,
      deezerApi: _deezerApi,
    );
  }

  AndroidAutoBrowser? _autoBrowser;

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    // "Reanudar" de Android (tarjeta de medios tras cerrar la app, Android
    // Auto al arrancar): pide la última pista bajo la raíz de recientes.
    if (parentMediaId == AudioService.recentRootId) {
      final track = _controller.state.currentTrack;
      return track == null ? const [] : [_toMediaItem(track).copyWith(playable: true)];
    }
    return await _browser?.children(parentMediaId) ?? const [];
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    if (mediaId == _controller.state.currentTrack?.id) {
      await _controller.play();
      return;
    }
    final sep = mediaId.lastIndexOf('|');
    if (sep > 0 && mediaId.substring(0, sep) == 'auto:search') {
      final index = int.tryParse(mediaId.substring(sep + 1)) ?? 0;
      if (_lastSearch.isEmpty) return;
      await _controller.setQueue(_lastSearch, startIndex: index.clamp(0, _lastSearch.length - 1));
      return;
    }
    final request = await _browser?.resolvePlay(mediaId);
    if (request == null) return;
    var start = request.startIndex;
    if (request.shuffle) {
      if (!_controller.state.isShuffle) _controller.toggleShuffle();
      start = RadioService.pickShuffledStartIndex(request.tracks.length, math.Random());
    }
    await _controller.setQueue(request.tracks, startIndex: start, activeContextId: request.contextId);
    final onStarted = request.onStarted;
    if (onStarted != null) unawaited(onStarted().catchError((_) {}));
  }

  @override
  Future<List<MediaItem>> search(String query, [Map<String, dynamic>? extras]) async {
    final api = _deezerApi;
    if (api == null || query.trim().isEmpty) return const [];
    try {
      final result = await api.search(query, type: DeezerSearchType.track, enrich: false);
      _lastSearch = [for (final t in result.tracks.take(30)) t.toSyncoraTrack()];
      return [
        for (var i = 0; i < _lastSearch.length; i++) AndroidAutoBrowser.trackItem('auto:search|$i', _lastSearch[i]),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// "Ok Google, pon X en Syncora": busca y reproduce el mejor resultado.
  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) async {
    final items = await search(query, extras);
    if (items.isEmpty) return;
    await _controller.setQueue(_lastSearch, startIndex: 0);
  }

  @override
  Future<void> onTaskRemoved() async {
    await stop();
    await super.onTaskRemoved();
  }
}
