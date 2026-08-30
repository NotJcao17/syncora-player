import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/widgets.dart';

import '../../core/extraction/extraction_service.dart';
import '../../core/extraction/models/extraction_request.dart';
import '../../core/extraction/models/extraction_result.dart';
import '../../core/extraction/retry_policy.dart';
import '../../data/apis/deezer_api.dart';
import '../../data/local_db/daos/downloaded_track_dao.dart';
import '../../data/local_db/daos/listening_history_dao.dart';
import '../../data/local_db/syncora_database.dart' show DownloadedTrack;
import '../../data/models/deezer/deezer_track.dart';

import 'audio_engine/audio_engine_state.dart';
import 'player_models.dart';
import 'radio/radio_service.dart';
import 'session/player_session_storage.dart';

/// Snapshot inmutable del estado completo del reproductor (cola dual +
/// reproducción).
///
/// Modelo de cola dual (Fase 7.A, ver `docs/plan_fase_7.md` D-1/D-2/D-3):
/// - [manualQueue]: lo que el usuario agregó explícitamente ("reproducir a
///   continuación" / "agregar a la cola"). FIFO, sobrevive a cambios de
///   shuffle/playlist, nunca la tocan las funciones de IA.
/// - [autoQueue]: regenerable, viene del contexto activo
///   (playlist/álbum/etc. — ver [originalContextTracks]).
/// - En cada avance, la manual se prioriza sobre la automática (D-1).
/// - [history]: pila única de reproducción (sin importar de qué cola vino
///   la pista) para "anterior" (D-3), acotada a 50 entradas.
@immutable
class SyncoraPlayerState {
  /// Pista activa (null si no suena nada). Ya no se deriva de un índice
  /// sobre una lista plana — es un campo propio.
  final SyncoraTrack? currentTrack;

  /// De qué cola provino [currentTrack] (null si no suena nada).
  final QueueOrigin? currentOrigin;

  /// Cola manual, FIFO (D-2).
  final List<SyncoraTrack> manualQueue;

  /// Cola automática, regenerable desde [originalContextTracks].
  final List<SyncoraTrack> autoQueue;

  /// Snapshot inmutable del contexto activo completo (la playlist/álbum tal
  /// como se pasó a [setQueue]), usado para regenerar [autoQueue] al
  /// togglear shuffle o al hacer loop con repeat-all.
  final List<SyncoraTrack> originalContextTracks;

  /// Pila de historial de reproducción único (D-3): más reciente al final,
  /// acotada a 50 entradas (se descarta la más antigua al superar el cupo).
  final List<HistoryEntry> history;

  final AudioEngineState engine;
  final SyncoraRepeatMode repeatMode;
  final bool shuffle;
  final bool skipSilence;
  final String? activeContextId;

  bool get isShuffle => shuffle;
  bool get isSkipSilence => skipSilence;

  /// Último error de extracción relevante (403 / red / not found). Lo usa la UI
  /// para mostrar un mensaje (Pitfalls #11 y #14: pausa inmediata, no bucle).
  final ExtractionError? lastError;
  final String? lastErrorMessage;

  /// Ids de pista marcadas "no disponible esta sesión" tras un fallo lógico
  /// de extracción (Fase 7.C.2, D-21). **Solo de sesión, nunca persistido**:
  /// vive en memoria dentro de este estado, así que se resetea solo al
  /// reiniciar el controlador (la app) — nunca se escribe en
  /// `PlayerSessionData`/`PlayerSessionStorage` a propósito.
  final Set<String> unavailableTrackIds;

  /// Último aviso puntual del reproductor para la UI (Fase 7.C + H-6). A
  /// diferencia de [lastError]/[lastErrorMessage] (que se limpian al
  /// avanzar con éxito, ver `_advance()`), este campo NUNCA se limpia solo
  /// — es un registro de "último evento", y la UI lo consume comparando
  /// [PlayerNotice.id] contra el de la emisión anterior (ver `app_shell.dart`).
  final PlayerNotice? notice;

  const SyncoraPlayerState({
    this.currentTrack,
    this.currentOrigin,
    this.manualQueue = const [],
    this.autoQueue = const [],
    this.originalContextTracks = const [],
    this.history = const [],
    this.engine = AudioEngineState.initial,
    this.repeatMode = SyncoraRepeatMode.off,
    this.shuffle = false,
    this.skipSilence = false,
    this.activeContextId,
    this.lastError,
    this.lastErrorMessage,
    this.unavailableTrackIds = const {},
    this.notice,
  });

  static const SyncoraPlayerState initial = SyncoraPlayerState();

  SyncoraPlayerState copyWith({
    SyncoraTrack? currentTrack,
    bool clearCurrentTrack = false,
    QueueOrigin? currentOrigin,
    bool clearCurrentOrigin = false,
    List<SyncoraTrack>? manualQueue,
    List<SyncoraTrack>? autoQueue,
    List<SyncoraTrack>? originalContextTracks,
    List<HistoryEntry>? history,
    AudioEngineState? engine,
    SyncoraRepeatMode? repeatMode,
    bool? shuffle,
    bool? skipSilence,
    String? activeContextId,
    bool clearContext = false,
    ExtractionError? lastError,
    String? lastErrorMessage,
    bool clearError = false,
    Set<String>? unavailableTrackIds,
    PlayerNotice? notice,
  }) {
    return SyncoraPlayerState(
      currentTrack: clearCurrentTrack ? null : (currentTrack ?? this.currentTrack),
      currentOrigin: clearCurrentOrigin ? null : (currentOrigin ?? this.currentOrigin),
      manualQueue: manualQueue ?? this.manualQueue,
      autoQueue: autoQueue ?? this.autoQueue,
      originalContextTracks: originalContextTracks ?? this.originalContextTracks,
      history: history ?? this.history,
      engine: engine ?? this.engine,
      repeatMode: repeatMode ?? this.repeatMode,
      shuffle: shuffle ?? this.shuffle,
      skipSilence: skipSilence ?? this.skipSilence,
      activeContextId: clearContext ? null : (activeContextId ?? this.activeContextId),
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastErrorMessage:
          clearError ? null : (lastErrorMessage ?? this.lastErrorMessage),
      unavailableTrackIds: unavailableTrackIds ?? this.unavailableTrackIds,
      notice: notice ?? this.notice,
    );
  }
}

/// Única fuente de la verdad del estado de reproducción (Pitfall #12:
/// `audio_service` v0.18+ corre en el Main Isolate, así que este controlador
/// puede compartir estado con la UI directamente).
///
/// Orquesta:
/// - [AudioEngine] (just_audio/media_kit): reproducción nativa.
/// - [ExtractionService]: resolución de URLs firmadas de YouTube.
/// - [RetryPolicy]: guard anti-bucle 403 (máx. 1 reintento).
/// - [PlayerSessionStorage]: persistencia de estado de reproducción y cola.

class SyncoraPlayerController extends ChangeNotifier {
  SyncoraPlayerController({
    required AudioEngine engine,
    required ExtractionService extractionService,
    DeezerApi? deezerApi,
    DownloadedTrackDao? downloadedTrackDao,
    ListeningHistoryDao? listeningHistoryDao,
    RadioService? radioService,
    bool Function()? isConnectedGetter,
    bool Function()? radioEnabledGetter,
    Duration Function()? crossfadeDurationGetter,
    VoidCallback? onListenRecorded,
    // Inyectable solo para tests (ver `syncora_player_controller_test.dart`,
    // grupo "Fase 7.F.2" -- un doble que devuelve una sesión restaurada con
    // `currentTrack: null` y `manualQueue` no vacía, el único camino
    // alcanzable en la app real hacia ese estado, del que dependen las
    // pruebas de regresión de D-1 sobre `interleaveIntoAutoQueue`).
    PlayerSessionStorage? sessionStorage,
  })  : _engine = engine, // ignore: prefer_initializing_formals
        _extractionService = extractionService, // ignore: prefer_initializing_formals
        _deezerApi = deezerApi, // ignore: prefer_initializing_formals
        _downloadedTrackDao = downloadedTrackDao, // ignore: prefer_initializing_formals
        _listeningHistoryDao = listeningHistoryDao, // ignore: prefer_initializing_formals
        _radioService = radioService, // ignore: prefer_initializing_formals
        _isConnectedGetter = isConnectedGetter, // ignore: prefer_initializing_formals
        _radioEnabledGetter = radioEnabledGetter, // ignore: prefer_initializing_formals
        _crossfadeDurationGetter = crossfadeDurationGetter, // ignore: prefer_initializing_formals
        _onListenRecorded = onListenRecorded, // ignore: prefer_initializing_formals
        _sessionStorage = sessionStorage ?? PlayerSessionStorage();

  final AudioEngine _engine;
  final ExtractionService _extractionService;
  final DeezerApi? _deezerApi;
  final DownloadedTrackDao? _downloadedTrackDao;
  final ListeningHistoryDao? _listeningHistoryDao;
  final RadioService? _radioService;
  final bool Function()? _isConnectedGetter;
  final bool Function()? _radioEnabledGetter;

  /// Duración configurada de crossfade (Fase 7.D.5, Configuración:
  /// off/2s/4s/6s). `null` o `Duration.zero` == "off" — mismo default
  /// conservador que `crossfadeDurationProvider`.
  final Duration Function()? _crossfadeDurationGetter;

  /// Se dispara al registrar una escucha, para subirla a la nube en el momento
  /// (ver `player_providers.dart`).
  final VoidCallback? _onListenRecorded;

  /// ¿La pista que está sonando AHORA MISMO se cargó desde descarga local
  /// (en vez de streaming)? Se actualiza justo después de arrancar
  /// reproducción con éxito desde cada camino en `_playCurrentInternal`, y
  /// se lee al llegar de nuevo a ese método para la pista SIGUIENTE, ANTES
  /// de sobreescribirlo — es la condición 3 del crossfade (Fase 7.D):
  /// nunca crossfade desde/hacia streaming (Pitfall #17).
  bool _currentPlaybackIsLocal = false;

  /// Id de la pista para la que ya se intentó (con éxito o no) el
  /// crossfade PREVENTIVO (Fase 7.D, rediseño) — evita reevaluar/disparar
  /// de nuevo en cada tick de posición mientras el tiempo restante siga
  /// bajo el umbral configurado. Comparar contra `_state.currentTrack?.id`
  /// en cada chequeo equivale a "resetear" el flag en todo punto que
  /// cambia `currentTrack` (setQueue/_advance/_retreat/playFromQueue/
  /// restauración de sesión/el propio crossfade preventivo) sin tener que
  /// acordarse de tocar cada uno de esos sitios por separado.
  String? _crossfadeAttemptedForTrackId;

  /// Guard SINCRÓNICO de "hay un crossfade en curso" (bug real reportado en
  /// pruebas manuales post-Fase 7: con crossfade activado, al terminar una
  /// canción el reproductor saltaba ~6 pistas de golpe).
  ///
  /// `_crossfadeAttemptedForTrackId` NO alcanzaba: compara contra
  /// `_state.currentTrack?.id`, pero `_runProactiveCrossfade` llama a
  /// `_commitAdvanceTo(next)` ANTES de `crossfadeToLocalSource(...)`, y ese
  /// método todavía tarda varios `await` (cargar y arrancar el motor
  /// entrante) en hacer el swap interno de cuál motor es el activo. Durante
  /// esa ventana — y después, durante todo el ramp de volumen — los ticks de
  /// posición seguían llegando del motor SALIENTE, con su posición ya a
  /// pocos segundos del EOF, mientras `currentTrack` ya era la pista
  /// siguiente: la comparación por id daba "todavía no se intentó" y
  /// disparaba OTRO crossfade preventivo, que avanzaba la cola otra vez, y
  /// así un avance por tick hasta que la cola se quedaba sin pistas
  /// descargadas. Como el wrapper solo tiene DOS motores, esa cascada además
  /// reusaba como motor "entrante" el mismo motor que estaba sonando, lo que
  /// explica el corte abrupto y el "suena un pedazo de la anterior y después
  /// la nueva" en vez de un fundido cruzado real.
  bool _isCrossfading = false;

  /// Generación del crossfade dueño de [_isCrossfading]: la liberación
  /// diferida del guard (programada para cuando el ramp de volumen del motor
  /// debería haber terminado) solo aplica si sigue siendo la vigente — así
  /// una transición nueva (skip manual, error, otra pista) nunca queda con
  /// el guard liberado por el temporizador de una transición anterior.
  int _crossfadeGeneration = 0;

  /// Margen sobre la duración del fade antes de liberar [_isCrossfading]:
  /// el ramp del motor avanza en pasos de 50ms y cada paso espera al motor
  /// nativo, así que termina siempre un poco después de la duración nominal.
  static const Duration _crossfadeSettleMargin = Duration(milliseconds: 400);

  final RetryPolicy _retryPolicy = RetryPolicy();
  final PlayerSessionStorage _sessionStorage;

  /// Cupo máximo de la pila de historial (D-3).
  static const int _historyCap = 50;

  /// Umbral de disparo de radio/cola infinita (Fase 7.B, D-10): cuando
  /// `autoQueue` baja a esta cantidad de pistas o menos, se genera un lote
  /// nuevo en segundo plano.
  static const int _radioTriggerThreshold = 5;

  /// Evita disparar fetches de radio concurrentes (Fase 7.B).
  bool _isFetchingRadio = false;

  /// Umbral del guard de cascada de auto-skip lógico (7.C.3): al llegar a
  /// esta cantidad de fallos lógicos SEGUIDOS (sin ningún éxito de
  /// reproducción entre medio), el auto-skip se detiene en vez de seguir
  /// saltando solo — evita vaciar una playlist entera en silencio cuando hay
  /// muchos matches rotos en fila.
  static const int _cascadeGuardThreshold = 3;

  /// Contador del guard de cascada (7.C.3). Se incrementa en cada fallo
  /// lógico (notFound/unknownError) que toma la rama de auto-skip dentro de
  /// `_handleExtractionError`. Se resetea a 0 en el mismo punto donde ya se
  /// resetea `_retryPolicy` por éxito de extracción (reproducción lograda),
  /// y también en los puntos de entrada donde el usuario interviene
  /// manualmente (`skipToNext` público, `playFromQueue`, `setQueue`) para no
  /// arrastrar un conteo viejo a una sesión de escucha distinta. La cascada
  /// interna de `_handleExtractionError`/`_advanceAndPlay` NUNCA pasa por
  /// esos puntos de entrada (ver docstring de `_advanceAndPlay`), así que
  /// resetear ahí nunca pisa un conteo en curso.
  int _consecutiveLogicalFailures = 0;

  /// Punto único de "reproducción lograda" (7.C.3, revisión de código: bug
  /// real corregido). `_playCurrentInternal` tiene DOS caminos de éxito —
  /// extracción online (`ExtractionSuccess`) y descarga local (que retorna
  /// antes de llegar siquiera al bloque de extracción) — y ambos rompen por
  /// igual una racha de fallos lógicos. Antes el reset solo vivía en el
  /// branch de `ExtractionSuccess`: una descarga local reproducida con
  /// éxito ENTRE dos fallos lógicos no lo rompía, así que el guard de
  /// cascada podía dispararse con fallos separados por una reproducción
  /// real (ej. cola `[bad1, bad2, descargada, bad3]` disparaba el guard en
  /// bad3 con solo 3 fallos, ninguno consecutivo de verdad). Factorizado
  /// para que ambos caminos de éxito llamen al mismo punto.
  void _onPlaybackStartedSuccessfully() {
    _consecutiveLogicalFailures = 0;
  }

  /// Contador monotónico de [PlayerNotice] (Fase 7.C + H-6): cada aviso
  /// nuevo que el controlador expone a la UI recibe un id distinto, para que
  /// la UI pueda distinguir "evento nuevo" de "el mismo estado, solo un
  /// rebuild" (ver docstring de `SyncoraPlayerState.notice`).
  int _noticeCounter = 0;

  PlayerNotice _nextNotice({
    required PlayerNoticeKind kind,
    required String message,
    String? trackTitle,
  }) {
    return PlayerNotice(
      id: ++_noticeCounter,
      kind: kind,
      message: message,
      trackTitle: trackTitle,
    );
  }

  /// Aviso de "esta acción necesita internet", emitido por los adaptadores
  /// del SO (pantalla de bloqueo de Android, botones del hover de la barra de
  /// tareas de Windows). Esos controles no tienen UI que apagar, así que en
  /// vez de deshabilitar un botón no ejecutan la acción y avisan por el mismo
  /// canal de [PlayerNotice] que ya consume `app_shell.dart`.
  void notifyActionBlockedOffline(String message) {
    _state = _state.copyWith(
      notice: _nextNotice(
        kind: PlayerNoticeKind.blockedOffline,
        message: message,
      ),
    );
    notifyListeners();
  }

  /// Contador monotónico de "sesión de contexto" (Fase 7.B, revisión: bug
  /// #1). Se incrementa en CADA llamada a [setQueue] (con o sin
  /// `activeContextId` — la mayoría de los call sites de la app, búsqueda/
  /// inicio/artista/track_tile, no pasan ninguno, así que comparar
  /// `activeContextId` no detectaba nada en el caso común: `null != null`
  /// siempre es falso). NO se incrementa en `_advance()`/`_retreat()`/
  /// `playFromQueue()` — avanzar dentro del MISMO contexto (siguiente pista
  /// de la misma playlist) sigue siendo una sesión válida para un lote de
  /// radio que estaba en vuelo. Es al nivel de "sesión de contexto", no al
  /// nivel de pista individual como `_playGeneration` (que sí cambia en
  /// cada pista y descartaría casi todos los lotes válidos si se
  /// reutilizara aquí).
  int _contextGeneration = 0;

  StreamSubscription<AudioEngineState>? _engineSub;
  StreamSubscription<void>? _completionSub;
  StreamSubscription<String>? _engineLogSub;
  bool _disposed = false;
  int? _restoredPositionSeconds;

  /// Id de la pista dueña de [_restoredPositionSeconds].
  ///
  /// Existe para que la posición restaurada NO pueda filtrarse a la pista
  /// siguiente (regla de `correcciones_qa_post_fase_7.md` §2.3: una ventana
  /// de supresión debe estar atada al id de su dueño o vencer sola). Sin
  /// esto, la barra de progreso "arrancaba en el segundo viejo" en cada
  /// pista posterior.
  String? _restoredPositionTrackId;

  /// Momento del último guardado de sesión disparado por el tick de
  /// posición del motor. Ventana puramente temporal: si la reproducción
  /// para, simplemente deja de guardarse — no hay ninguna bandera que
  /// alguien deba acordarse de limpiar.
  DateTime? _lastPeriodicSessionSave;

  /// Cada cuánto se persiste la posición mientras suena algo.
  ///
  /// Antes la sesión solo se guardaba en eventos discretos (play, pause,
  /// next…), así que cerrar la app en medio de una canción guardaba la
  /// posición del último evento — normalmente el segundo 0 del play.
  static const Duration _periodicSessionSaveInterval = Duration(seconds: 5);

  SyncoraPlayerState _state = SyncoraPlayerState.initial;

  SyncoraPlayerState get state => _state;

  // Flujo de logs para depuración.
  final StreamController<String> _logController =
      StreamController<String>.broadcast();
  Stream<String> get onLogMessage => _logController.stream;

  // Flag anti-reentrada: evita que skipToNext/skipToPrevious disparen cadenas
  // recursivas mientras una extracción está en curso.
  bool _isTransitioning = false;

  /// Inicializa suscripciones a los streams del motor y restaura sesión guardada.
  void init() {
    _engineSub = _engine.stateStream.listen(_onEngineState);
    _completionSub = _engine.completionStream.listen((_) => _onComplete());
    _engineLogSub = _engine.logStream.listen(_log);
    _restoreSession();
  }

  // ----------------------------------------------------------------------
  // API pública de control y gestión de cola
  // ----------------------------------------------------------------------

  /// Reemplaza el contexto activo (playlist/álbum/etc.) y (opcionalmente)
  /// arranca la reproducción desde [startIndex].
  ///
  /// Comportamiento (D-1): [originalContextTracks] se snapshotea completo,
  /// [autoQueue] se reemplaza por lo que sigue de [startIndex] en adelante
  /// (lo anterior se descarta, nunca sonó). **`manualQueue` NO se toca** —
  /// sobrevive a cualquier cambio de contexto, y sigue teniendo prioridad
  /// sobre la automática nueva en cuanto se agote.
  Future<void> setQueue(
    List<SyncoraTrack> tracks, {
    int startIndex = 0,
    bool autoplay = true,
    String? activeContextId,
  }) async {
    _restoredPositionSeconds = null;
    _restoredPositionTrackId = null;
    // 7.C.3: setQueue() es una intervención del usuario (nuevo contexto de
    // escucha) — no debe arrastrar un conteo de fallos lógicos de la sesión
    // de escucha anterior (ver docstring de `_consecutiveLogicalFailures`).
    _consecutiveLogicalFailures = 0;
    // Cada llamada a setQueue() es una sesión de contexto nueva (Fase 7.B,
    // revisión: bug #1) — incrementa en AMBAS ramas (tracks.isEmpty incluida)
    // para que un lote de radio en vuelo, originado antes de este cambio de
    // contexto, se descarte al resolver.
    _contextGeneration++;
    if (tracks.isEmpty) {
      await _microFadeOut();
      await _engine.stop();
      final newHistory = _pushHistory(_state.history, _state.currentTrack, _state.currentOrigin);
      _state = SyncoraPlayerState.initial.copyWith(
        skipSilence: _state.skipSilence,
        repeatMode: _state.repeatMode,
        shuffle: _state.shuffle,
        manualQueue: _state.manualQueue,
        history: List.unmodifiable(newHistory),
        clearContext: true,
        // D-21: el marcado "no disponible esta sesión" es de sesión, no de
        // contexto — vaciar la cola no debe "olvidar" pistas ya marcadas
        // rotas mientras la app siga abierta.
        unavailableTrackIds: _state.unavailableTrackIds,
      );
      _notify();
      _saveSession();
      return;
    }

    final clampedStart = startIndex.clamp(0, tracks.length - 1);
    final newCurrent = tracks[clampedStart];
    final rest = tracks.sublist(clampedStart + 1);
    // P1.6: si shuffle ya estaba activo, la autoQueue resultante debe salir
    // mezclada — no solo la que se regenera al togglear shuffle después.
    final newAuto = _state.shuffle ? (List<SyncoraTrack>.from(rest)..shuffle()) : rest;
    final newHistory = _pushHistory(_state.history, _state.currentTrack, _state.currentOrigin);

    _state = _state.copyWith(
      currentTrack: newCurrent,
      currentOrigin: QueueOrigin.auto,
      autoQueue: List.unmodifiable(newAuto),
      originalContextTracks: List.unmodifiable(tracks),
      history: List.unmodifiable(newHistory),
      activeContextId: activeContextId,
      clearContext: activeContextId == null,
      clearError: true,
    );
    _notify();
    _saveSession();
    if (autoplay) {
      await playCurrent();
    }
  }

  /// Salta directo a la pista en [index] de la cola [origin]. Las pistas
  /// anteriores a [index] en esa cola se descartan (nunca sonaron, no van a
  /// [SyncoraPlayerState.history]); las posteriores quedan intactas. La
  /// pista actual (si había una) sí va al historial, igual que en cualquier
  /// avance.
  ///
  /// Participa del guard [_isTransitioning] (P1.8) para que dos taps rápidos
  /// sobre la cola (o un tap que coincide con un skip en curso) no muten las
  /// colas dos veces en paralelo. `_skipSilently()` llama a la variante
  /// interna sin guard porque ya corre anidada dentro de una transición en
  /// curso (bloquearla ahí causaría un deadlock lógico).
  Future<void> playFromQueue(QueueOrigin origin, int index) async {
    if (_isTransitioning) return;
    _isTransitioning = true;
    // 7.C.3: elegir una pista de la cola a mano es una intervención del
    // usuario — no debe arrastrar un conteo de fallos lógicos viejo.
    _consecutiveLogicalFailures = 0;
    try {
      await _playFromQueueInternal(origin, index);
    } finally {
      _isTransitioning = false;
    }
  }

  Future<void> _playFromQueueInternal(QueueOrigin origin, int index) async {
    final sourceQueue = origin == QueueOrigin.manual ? _state.manualQueue : _state.autoQueue;
    if (index < 0 || index >= sourceQueue.length) return;

    _restoredPositionSeconds = null;
    _restoredPositionTrackId = null;

    final target = sourceQueue[index];
    final remaining = sourceQueue.sublist(index + 1);
    final newHistory = _pushHistory(_state.history, _state.currentTrack, _state.currentOrigin);

    _state = _state.copyWith(
      currentTrack: target,
      currentOrigin: origin,
      manualQueue: origin == QueueOrigin.manual ? List.unmodifiable(remaining) : _state.manualQueue,
      autoQueue: origin == QueueOrigin.auto ? List.unmodifiable(remaining) : _state.autoQueue,
      history: List.unmodifiable(newHistory),
      clearError: true,
    );
    _notify();
    _saveSession();
    await playCurrent();
  }

  Future<void> play() async {
    if (_state.engine.processingState == AudioProcessingState.idle && _state.currentTrack != null) {
      await playCurrent();
    } else {
      await _engine.play();
    }
  }

  Future<void> pause() async {
    await _engine.pause();
    _saveSession();
  }

  Future<void> seek(Duration position) async {
    await _engine.seek(position);
    _saveSession();
  }

  Future<void> stop() async {
    await _microFadeOut();
    await _engine.stop();
    _saveSession();
  }

  /// Entrada pública (tap del usuario / botón del SO). Participa del guard
  /// [_isTransitioning] real (P1.8): un segundo tap mientras la transición
  /// anterior sigue en curso se ignora en vez de correr en paralelo.
  Future<void> skipToNext() async {
    if (_isTransitioning) return;
    _isTransitioning = true;
    // 7.C.3: un skip manual del usuario (botón "siguiente", o el llamador
    // interno _onComplete()/resumeAfterCascadeGuard() tras una reproducción
    // lograda o una intervención explícita) no debe arrastrar un conteo de
    // fallos lógicos de una cadena de auto-skip anterior — la cascada
    // interna nunca pasa por este método público (ver docstring de
    // _advanceAndPlay), así que resetear acá nunca pisa un conteo en curso.
    _consecutiveLogicalFailures = 0;
    try {
      await _advanceAndPlay();
    } finally {
      _isTransitioning = false;
    }
  }

  /// Acción "Reintentar" del aviso de guard de cascada (7.C.3): intenta
  /// avanzar una vez más a través del [skipToNext] público (guardado por
  /// [_isTransitioning] como cualquier otro skip iniciado por el usuario).
  ///
  /// Revisión de código (bug real, corregido): el reset del contador NO se
  /// hace acá antes de llamar a [skipToNext] — [skipToNext] ya lo resetea
  /// él mismo, pero recién DESPUÉS de pasar su propio guard de reentrada
  /// (`if (_isTransitioning) return;`). Resetear acá primero rompía esa
  /// garantía: si el usuario tocaba "Reintentar" dos veces rápido mientras
  /// la cascada seguía en vuelo, el segundo tap no hacía nada útil (el
  /// guard de [skipToNext] lo descartaba) pero YA había reseteado el
  /// contador a 0 — la cascada en curso necesitaba entonces 3 fallos MÁS
  /// para volver a dispararse, pudiendo posponerse indefinidamente a fuerza
  /// de taps repetidos. Delegar el reset por completo a [skipToNext] cierra
  /// ese hueco.
  Future<void> resumeAfterCascadeGuard() async {
    await skipToNext();
  }

  /// Núcleo de "avanzar y reproducir", SIN el guard de [skipToNext]. Existe
  /// por separado porque cadenas de fallos internas (notFound consecutivos
  /// en `_handleExtractionError`, error del motor en `_onEngineState`) deben
  /// poder encadenar varios avances aunque ya estén corriendo anidadas
  /// dentro de un `skipToNext()` guardado — si llamaran al `skipToNext()`
  /// público, el guard las bloquearía a sí mismas (deadlock lógico) y la
  /// cascada de auto-skip se trabaría en el primer fallo.
  Future<void> _advanceAndPlay() async {
    final advanced = _advance();
    if (!advanced) {
      // Fin de ambas colas sin repeat-all posible: intentar Autoplay con
      // recomendaciones de Deezer antes de rendirse.
      final handledAutoplay = await _tryAutoplay();
      if (!handledAutoplay) {
        await _engine.pause();
        _saveSession();
      }
      return;
    }
    _notify();
    _saveSession();
    await playCurrent();
  }

  /// Dispara Autoplay al agotarse ambas colas (sin repeat-all disponible).
  /// Las recomendaciones se anexan al final de [SyncoraPlayerState.autoQueue]
  /// y se sigue el flujo normal de avance — nunca se toca la manual.
  ///
  /// Revisión de 7.B (bug #3): el toggle de Configuración de radio debe
  /// apagar TODO el auto-relleno de `autoQueue`, no solo
  /// [_maybeFetchRadio]. Sin este chequeo, desactivar el toggle no evitaba
  /// que Autoplay (el mecanismo previo a 7.B) siguiera anexando
  /// recomendaciones de Deezer al vaciarse ambas colas del todo.
  Future<bool> _tryAutoplay() async {
    if (_deezerApi == null) return false;
    if (!(_radioEnabledGetter?.call() ?? true)) return false;
    final seedTrack = _state.currentTrack;
    if (seedTrack == null) return false;

    int? deezerTrackId = int.tryParse(seedTrack.id);

    // Si el ID no es un int válido, buscar la canción en Deezer para obtener su ID
    if (deezerTrackId == null) {
      try {
        final searchRes = await _deezerApi.search('${seedTrack.artist} ${seedTrack.title}');
        if (searchRes.tracks.isNotEmpty) {
          deezerTrackId = searchRes.tracks.first.id;
        }
      } catch (_) {}
    }

    List<DeezerTrack> recommendations = [];
    if (deezerTrackId != null && deezerTrackId > 0) {
      try {
        recommendations = await _deezerApi.getTrackRecommendations(deezerTrackId);
      } catch (e) {
        _log('[Autoplay] Error obteniendo recomendaciones: $e');
      }
    }

    if (recommendations.isEmpty) {
      try {
        recommendations = await _deezerApi.getTopCharts();
      } catch (_) {}
    }

    if (recommendations.isEmpty) return false;

    // Convertir a SyncoraTrack y filtrar canciones que ya están en alguna
    // cola o son la propia semilla, para no repetir.
    final existingIds = <String>{
      seedTrack.id,
      ..._state.manualQueue.map((t) => t.id),
      ..._state.autoQueue.map((t) => t.id),
    };
    final newTracks = recommendations
        .map((t) => t.toSyncoraTrack())
        .where((t) => !existingIds.contains(t.id))
        .toList();

    if (newTracks.isEmpty) return false;

    _log('[Autoplay] ${newTracks.length} pistas similares añadidas a la cola automáticamente.');
    final updatedAuto = List<SyncoraTrack>.from(_state.autoQueue)..addAll(newTracks);
    _state = _state.copyWith(autoQueue: List.unmodifiable(updatedAuto));

    final advanced = _advance();
    if (!advanced) return false; // no debería pasar: acabamos de anexar pistas

    _notify();
    _saveSession();
    await playCurrent();
    return true;
  }

  DateTime? _lastPrevTapTime;

  Future<void> skipToPrevious() async {
    if (_isTransitioning) return;
    _isTransitioning = true;
    // 7.C.3: mismo criterio que los demás entry points manuales
    // (skipToNext/playFromQueue/setQueue) — "anterior" también puede
    // terminar en _handleExtractionError si la pista anterior falla (el
    // aviso/marcado gris debe seguir aplicando igual, eso no cambia), pero
    // no debe arrastrar el conteo de una cadena de auto-skip previa hacia
    // "siguiente".
    _consecutiveLogicalFailures = 0;
    try {
      final now = DateTime.now();
      final isDoubleTap = _lastPrevTapTime != null && now.difference(_lastPrevTapTime!) < const Duration(milliseconds: 1500);
      _lastPrevTapTime = now;

      // Si llevamos >3s reproduciéndola y NO es doble tap rápido, reiniciar la pista actual.
      if (!isDoubleTap && _state.engine.position.inSeconds > 3) {
        // Reinicio explícito del usuario: es un intento de escucha nuevo,
        // no la continuación del anterior (Fase 7.0 — hallazgo de revisión).
        final current = _state.currentTrack;
        if (current != null) _beginListenTracking(current);
        await _engine.seek(Duration.zero);
        return;
      }
      final retreated = _retreat();
      if (!retreated) {
        await _engine.seek(Duration.zero);
        return;
      }
      _notify();
      _saveSession();
      await playCurrent();
    } finally {
      _isTransitioning = false;
    }
  }

  void setRepeatMode(SyncoraRepeatMode mode) {
    _state = _state.copyWith(repeatMode: mode);
    _notify();
    _saveSession();
  }

  void cycleRepeatMode() {
    final next = switch (_state.repeatMode) {
      SyncoraRepeatMode.off => SyncoraRepeatMode.all,
      SyncoraRepeatMode.all => SyncoraRepeatMode.one,
      SyncoraRepeatMode.one => SyncoraRepeatMode.off,
    };
    setRepeatMode(next);
  }

  /// Inserta la pista al FRENTE de la cola manual ("reproducir a
  /// continuación") — se reproducirá antes que cualquier otra pista manual
  /// ya en cola (D-1/D-2). Si no había nada sonando, la promueve de
  /// inmediato a `currentTrack` (sin arrancar reproducción — deja el estado
  /// "listo, pausado", igual que el comportamiento viejo que solo fijaba
  /// `currentIndex` sin forzar autoplay) para que no quede inalcanzable
  /// dentro de la cola.
  void playNext(SyncoraTrack track) {
    final updated = List<SyncoraTrack>.from(_state.manualQueue)..insert(0, track);
    _state = _state.copyWith(manualQueue: List.unmodifiable(updated));
    if (_state.currentTrack == null) {
      _advance();
    }
    _notify();
    _saveSession();
  }

  /// Agrega una pista al FINAL de la cola manual (FIFO, D-2): agregar A y
  /// luego B reproduce A, luego B. Mismo tratamiento que [playNext] cuando
  /// no había nada sonando (ver ahí).
  void addToQueue(SyncoraTrack track) {
    final updated = List<SyncoraTrack>.from(_state.manualQueue)..add(track);
    _state = _state.copyWith(manualQueue: List.unmodifiable(updated));
    if (_state.currentTrack == null) {
      _advance();
    }
    _notify();
    _saveSession();
  }

  /// Fase 7.F.2 -- "Crear cola con IA", modo "añadir como cola manual":
  /// agrega varias pistas ya resueltas contra Deezer al FINAL de la cola
  /// manual de una sola vez, en el orden dado (FIFO, D-2) -- equivalente a
  /// llamar [addToQueue] una vez por pista, pero en una sola mutación/
  /// notificación en vez de una por pista. Mismo tratamiento que
  /// [addToQueue] cuando no había nada sonando (promueve la primera a
  /// `currentTrack`, sin autoplay).
  void addAllToQueue(List<SyncoraTrack> tracks) {
    if (tracks.isEmpty) return;
    final updated = List<SyncoraTrack>.from(_state.manualQueue)..addAll(tracks);
    _state = _state.copyWith(manualQueue: List.unmodifiable(updated));
    if (_state.currentTrack == null) {
      _advance();
    }
    _notify();
    _saveSession();
  }

  /// Fase 7.F.2 -- "Crear cola con IA", modo "intercalar" (D-9): mezcla
  /// [tracks] (ya resueltas contra Deezer) DENTRO de la cola automática
  /// existente -- nunca toca `manualQueue` (D-1).
  ///
  /// El paso de intercalado es ADAPTATIVO (`autoQueue.length ~/
  /// tracks.length`, mínimo 1), no un "cada 3" fijo: con un paso fijo, en el
  /// caso de uso principal (atajo "Mejorar esta cola" -> 25 sugerencias
  /// contra una `autoQueue` típica bastante más corta) casi todo el sobrante
  /// terminaba pegado en un solo bloque al final, sin ninguna sensación de
  /// intercalado real (hallazgo de la revisión independiente de 7.F.2, no
  /// estaba en el plan original). El paso adaptativo reparte las
  /// sugerencias a lo largo de TODA la cola automática existente; solo
  /// queda un bloque residual al final cuando hay estructuralmente más
  /// sugerencias que huecos posibles (`autoQueue` muy corta).
  void interleaveIntoAutoQueue(List<SyncoraTrack> tracks) {
    if (tracks.isEmpty) return;
    final current = _state.autoQueue;
    final result = <SyncoraTrack>[];
    if (current.isEmpty) {
      result.addAll(tracks);
    } else {
      final stride = (current.length ~/ tracks.length).clamp(1, current.length);
      var suggestionIndex = 0;
      for (var i = 0; i < current.length; i++) {
        result.add(current[i]);
        if ((i + 1) % stride == 0 && suggestionIndex < tracks.length) {
          result.add(tracks[suggestionIndex]);
          suggestionIndex++;
        }
      }
      while (suggestionIndex < tracks.length) {
        result.add(tracks[suggestionIndex]);
        suggestionIndex++;
      }
    }
    _state = _state.copyWith(autoQueue: List.unmodifiable(result));
    // D-1: si no hay nada sonando, arrancar reproducción es un efecto
    // esperado (mismo tratamiento que `addToQueue`/`addAllToQueue`) -- pero
    // SOLO si la cola manual también está vacía. Con `manualQueue` no vacía
    // (ej. tras restaurar una sesión con `currentTrack` null pero pistas
    // pendientes en "A continuación", ver `_restoreSession`), `_advance()`
    // promovería una pista de la cola manual del usuario a "sonando ahora"
    // como efecto secundario de una operación de IA sobre la automática --
    // exactamente lo que D-1 prohíbe. La manual mantiene su prioridad
    // normal de reproducción intacta para cuando el usuario sí le dé play.
    if (_state.currentTrack == null && _state.manualQueue.isEmpty) {
      _advance();
    }
    _notify();
    _saveSession();
  }

  /// Reordena elementos SOLO dentro de la cola [origin] — no se permite
  /// arrastrar entre secciones (7.A.10).
  void reorderQueue(QueueOrigin origin, int oldIndex, int newIndex) {
    final source = origin == QueueOrigin.manual ? _state.manualQueue : _state.autoQueue;
    if (oldIndex < 0 || oldIndex >= source.length) return;

    int targetIndex = newIndex;
    if (oldIndex < targetIndex) {
      targetIndex -= 1;
    }
    if (targetIndex < 0 || targetIndex >= source.length) return;
    if (oldIndex == targetIndex) return;

    final updated = List<SyncoraTrack>.from(source);
    final track = updated.removeAt(oldIndex);
    updated.insert(targetIndex, track);

    if (origin == QueueOrigin.manual) {
      _state = _state.copyWith(manualQueue: List.unmodifiable(updated));
    } else {
      _state = _state.copyWith(autoQueue: List.unmodifiable(updated));
    }
    _notify();
    _saveSession();
  }

bool get _isTestEnv {
  try {
    final name = WidgetsBinding.instance.runtimeType.toString();
    return name.contains('Test') || name.contains('Automated');
  } catch (_) {
    return true;
  }
}

  /// Micro fade-out de audio (120-150ms) antes de cambiar de pista o detener el motor.
  ///
  /// Se ejecuta a nivel interno del motor de audio ([AudioEngine.microFadeOut]) sin alterar
  /// el volumen canónico/observable de la UI, evitando cualquier artefacto pop/corte abrupto
  /// y garantizando que la barra de volumen no se mueva visualmente ni parpadee el botón de play/pause.
  Future<void> _microFadeOut() async {
    if (!_state.engine.playing || _isTestEnv) return;
    try {
      await _engine.microFadeOut();
    } catch (e) {
      _log('[Audio] Error en micro fade-out: $e');
    }
  }

  /// Elimina una pista de la cola [origin] sin afectar `currentTrack` ni el
  /// historial — nunca estuvo sonando.
  void removeFromQueue(QueueOrigin origin, int index) {
    final source = origin == QueueOrigin.manual ? _state.manualQueue : _state.autoQueue;
    if (index < 0 || index >= source.length) return;

    final updated = List<SyncoraTrack>.from(source)..removeAt(index);
    if (origin == QueueOrigin.manual) {
      _state = _state.copyWith(manualQueue: List.unmodifiable(updated));
    } else {
      _state = _state.copyWith(autoQueue: List.unmodifiable(updated));
    }
    _notify();
    _saveSession();
  }

  /// Vacía solo la cola manual (D-1: lo que el usuario agregó a mano) —
  /// nunca la automática ni `originalContextTracks`. La cola automática
  /// sigue avanzando con el contexto/playlist activo; limpiarla también no
  /// es lo que el botón "Limpiar cola" promete, y requeriría que el usuario
  /// cambie explícitamente de contexto (D-1). No toca `currentTrack` ni el
  /// historial.
  void clearQueue() {
    _state = _state.copyWith(manualQueue: const []);
    _notify();
    _saveSession();
  }

  void setShuffle(bool enabled) {
    final reordered = _reorderAutoQueueForShuffle(enabled);
    _state = _state.copyWith(shuffle: enabled, autoQueue: List.unmodifiable(reordered));
    _notify();
    _saveSession();
  }

  void toggleShuffle() {
    setShuffle(!_state.shuffle);
  }

  /// Reordena `autoQueue` in-place al cambiar shuffle↔normal.
  ///
  /// P0.1 (bug corregido): la versión anterior DERIVABA la nueva `autoQueue`
  /// filtrando `originalContextTracks` — cualquier pista de `autoQueue` que
  /// no viniera de ahí (ej. las recomendaciones que anexa `_tryAutoplay()`)
  /// desaparecía por completo al togglear shuffle. Ahora se reordena/mezcla
  /// la `autoQueue` **actual** directamente: con shuffle, se mezcla tal
  /// cual; sin shuffle, se usa `originalContextTracks` solo como orden
  /// canónico para las pistas que vienen de ahí, preservando cualquier
  /// extra en su orden relativo actual, al final. Compara por `.id` porque
  /// `SyncoraTrack` no tiene `==` de valor.
  List<SyncoraTrack> _reorderAutoQueueForShuffle(bool shuffle) {
    final current = List<SyncoraTrack>.from(_state.autoQueue);
    if (shuffle) {
      current.shuffle();
      return current;
    }

    final currentIds = current.map((t) => t.id).toSet();
    final canonical = _state.originalContextTracks.where((t) => currentIds.contains(t.id)).toList();
    final canonicalIds = canonical.map((t) => t.id).toSet();
    final extras = current.where((t) => !canonicalIds.contains(t.id)).toList();
    return [...canonical, ...extras];
  }

  Future<void> setSkipSilence(bool enabled) async {
    await _engine.setSkipSilenceEnabled(enabled);
    _state = _state.copyWith(skipSilence: enabled);
    _notify();
  }

  Future<void> setSpeed(double speed) => _engine.setSpeed(speed);
  Future<void> setVolume(double volume) => _engine.setVolume(volume);

  void clearError() {
    _state = _state.copyWith(clearError: true);
    _notify();
  }

  // ----------------------------------------------------------------------
  // Lógica interna de avance/retroceso de cola (Fase 7.A)
  // ----------------------------------------------------------------------

  /// Empuja [track] (con su [origin]) al historial, respetando el cupo de
  /// [_historyCap] (descarta la entrada más antigua al superarlo). `null` en
  /// [origin] se trata como `auto` (no debería ocurrir en la práctica, es
  /// una red de seguridad). Si [track] es `null` (nada sonaba), no hace nada.
  List<HistoryEntry> _pushHistory(List<HistoryEntry> history, SyncoraTrack? track, QueueOrigin? origin) {
    if (track == null) return history;
    final updated = List<HistoryEntry>.from(history)
      ..add(HistoryEntry(track, origin ?? QueueOrigin.auto));
    if (updated.length > _historyCap) {
      updated.removeAt(0);
    }
    return updated;
  }

  /// Espía, de SOLO LECTURA (sin mutar `_state`), cuál sería la próxima
  /// pista si se avanzara ahora mismo — misma prioridad que [_advance]
  /// (manual antes que automática, D-1). Si ambas colas están vacías,
  /// devuelve `null` incluso cuando repeat-all podría regenerar la
  /// automática desde `originalContextTracks` — esa regeneración es una
  /// MUTACIÓN real (además de potencialmente mezclar con shuffle), así que
  /// no se puede "espiar" sin comprometerse; solo [_advance] la ejecuta de
  /// verdad, cuando el avance ya es definitivo.
  ///
  /// Fase 7.D (rediseño): [_advance] y el chequeo preventivo de crossfade
  /// (`_maybeCrossfadeProactively`) comparten esta única función para no
  /// duplicar la lógica de prioridad manual-antes-que-auto en dos sitios.
  (SyncoraTrack, QueueOrigin)? _peekNext() {
    if (_state.manualQueue.isNotEmpty) {
      return (_state.manualQueue.first, QueueOrigin.manual);
    }
    if (_state.autoQueue.isNotEmpty) {
      return (_state.autoQueue.first, QueueOrigin.auto);
    }
    return null;
  }

  /// Avanza a la siguiente pista respetando D-1 (manual antes que
  /// automática) y D-3 (regenerar la automática desde el contexto si
  /// repeat-all agotó ambas colas). Muta `_state`
  /// (currentTrack/currentOrigin/colas/historial) pero **no** notifica,
  /// guarda sesión ni llama a [playCurrent] — el llamador decide (
  /// [skipToNext] reproduce de inmediato; `_skipSilently` itera sin
  /// reproducir hasta encontrar una pista descargada).
  ///
  /// Devuelve `false` si no hay ninguna pista siguiente disponible.
  bool _advance() {
    var peeked = _peekNext();
    if (peeked == null &&
        _state.repeatMode == SyncoraRepeatMode.all &&
        _state.originalContextTracks.isNotEmpty) {
      // Ambas colas agotadas pero hay repeat-all: acá sí se ejecuta la
      // regeneración real (a diferencia de [_peekNext], que nunca la hace)
      // y se vuelve a espiar ahora que `autoQueue` ya tiene contenido.
      final regenerated = List<SyncoraTrack>.from(_state.originalContextTracks);
      if (_state.shuffle) regenerated.shuffle();
      _state = _state.copyWith(autoQueue: List.unmodifiable(regenerated));
      peeked = _peekNext();
    }
    if (peeked == null) return false;

    final (next, nextOrigin) = peeked;
    // `peeked` es siempre el primero de su cola (ver [_peekNext]) y no hay
    // ningún `await` entre el peek y este punto, así que sigue estando ahí
    // — [_commitAdvanceTo] lo remueve por id, lo que en este caso coincide
    // exactamente con removerlo por posición (índice 0).
    _commitAdvanceTo(next, nextOrigin);
    return true;
  }

  /// Aplica la mutación de "avanzar a [track]" (empujar la actual al
  /// historial, sacar [track] de su cola de [origin], actualizar
  /// `currentTrack`/`currentOrigin`) — el núcleo compartido detrás de
  /// [_advance].
  ///
  /// Fase 7.D (rediseño): el crossfade preventivo también usa esto
  /// directamente (no pasando por [_advance]) porque necesita confirmar el
  /// avance hacia una pista EXACTA que ya peekeó y verificó como
  /// descargada — pueden haber pasado varios ticks entre ese peek y este
  /// punto (el chequeo de descarga es async), tiempo en el que la cola
  /// pudo reordenarse desde la pantalla de Cola. Por eso remueve por **id**
  /// en vez de por posición: si [track] ya no está en su cola de origen
  /// (la quitaron mientras tanto), igual se confirma como `currentTrack`
  /// (el motor ya se comprometió a reproducirla) pero no se toca la cola
  /// de más.
  void _commitAdvanceTo(SyncoraTrack track, QueueOrigin origin) {
    final newHistory = _pushHistory(_state.history, _state.currentTrack, _state.currentOrigin);

    List<SyncoraTrack> newManual = _state.manualQueue;
    List<SyncoraTrack> newAuto = _state.autoQueue;
    if (origin == QueueOrigin.manual) {
      final idx = _state.manualQueue.indexWhere((t) => t.id == track.id);
      if (idx != -1) {
        newManual = List<SyncoraTrack>.from(_state.manualQueue)..removeAt(idx);
      }
    } else {
      final idx = _state.autoQueue.indexWhere((t) => t.id == track.id);
      if (idx != -1) {
        newAuto = List<SyncoraTrack>.from(_state.autoQueue)..removeAt(idx);
      }
    }

    _state = _state.copyWith(
      currentTrack: track,
      currentOrigin: origin,
      manualQueue: List.unmodifiable(newManual),
      autoQueue: List.unmodifiable(newAuto),
      history: List.unmodifiable(newHistory),
      clearError: true,
    );
  }

  /// Retrocede a la última pista del historial (D-3): al volver desde una
  /// pista manual, regresa a esa pista manual, no a la automática. La pista
  /// actual (si había una) vuelve al FRENTE de SU PROPIA cola de origen, así
  /// "siguiente" tras un "anterior" reproduce la misma pista de la que
  /// veníamos. Igual que [_advance], no notifica ni reproduce.
  ///
  /// Devuelve `false` si el historial está vacío.
  bool _retreat() {
    if (_state.history.isEmpty) return false;

    final newHistory = List<HistoryEntry>.from(_state.history);
    final entry = newHistory.removeLast();

    List<SyncoraTrack> newManual = _state.manualQueue;
    List<SyncoraTrack> newAuto = _state.autoQueue;
    final current = _state.currentTrack;
    if (current != null) {
      if (_state.currentOrigin == QueueOrigin.manual) {
        newManual = List<SyncoraTrack>.from(_state.manualQueue)..insert(0, current);
      } else {
        newAuto = List<SyncoraTrack>.from(_state.autoQueue)..insert(0, current);
      }
    }

    _state = _state.copyWith(
      currentTrack: entry.track,
      currentOrigin: entry.origin,
      manualQueue: List.unmodifiable(newManual),
      autoQueue: List.unmodifiable(newAuto),
      history: List.unmodifiable(newHistory),
      clearError: true,
    );
    return true;
  }

  // ----------------------------------------------------------------------
  // Lógica interna & Persistencia de Sesión
  // ----------------------------------------------------------------------

  void _saveSession() {
    _sessionStorage.saveSession(
      currentTrack: _state.currentTrack,
      currentOrigin: _state.currentOrigin,
      manualQueue: _state.manualQueue,
      autoQueue: _state.autoQueue,
      originalContextTracks: _state.originalContextTracks,
      history: _state.history,
      positionSeconds: _state.engine.position.inSeconds,
      volume: _state.engine.volume,
      repeatMode: _state.repeatMode,
      shuffle: _state.shuffle,
      activeContextId: _state.activeContextId,
    );
  }

  Future<void> _restoreSession() async {
    final session = await _sessionStorage.loadSession();
    if (session == null) return;
    if (session.currentTrack == null && session.manualQueue.isEmpty && session.autoQueue.isEmpty) {
      return;
    }

    // P2: solo tiene sentido "recordar" una posición a restaurar si hay una
    // pista a la que aplicarla — sin esto, una sesión con manualQueue no
    // vacía pero currentTrack null (ej. tras un setQueue([]) guardado)
    // dejaba `_restoredPositionSeconds` seteado sin destino.
    if (session.currentTrack != null) {
      _restoredPositionSeconds = session.positionSeconds;
      _restoredPositionTrackId = session.currentTrack!.id;
    }
    final restoredDuration = session.currentTrack?.duration ?? Duration.zero;

    _state = _state.copyWith(
      currentTrack: session.currentTrack,
      clearCurrentTrack: session.currentTrack == null,
      currentOrigin: session.currentOrigin,
      clearCurrentOrigin: session.currentOrigin == null,
      manualQueue: List.unmodifiable(session.manualQueue),
      autoQueue: List.unmodifiable(session.autoQueue),
      originalContextTracks: List.unmodifiable(session.originalContextTracks),
      history: List.unmodifiable(session.history),
      repeatMode: session.repeatMode,
      shuffle: session.shuffle,
      activeContextId: session.activeContextId,
      clearContext: session.activeContextId == null,
      engine: _state.engine.copyWith(
        position: Duration(seconds: session.positionSeconds),
        duration: restoredDuration,
        volume: session.volume,
        playing: false,
        processingState: AudioProcessingState.idle,
      ),
      clearError: true,
    );
    await _engine.setVolume(session.volume);
    _notify();
    _log('[Session] Sesión restaurada: ${session.manualQueue.length + session.autoQueue.length} '
        'pistas en cola, posición: ${session.positionSeconds}s, volumen: ${session.volume} (pausado)');

    if (session.currentTrack != null) {
      _prewarmSessionTrack(session.currentTrack!);
    }
  }

  /// Precalienta silenciosamente la extracción de la URL en segundo plano tras restaurar sesión,
  /// de modo que al pulsar Play la pista comience a sonar de inmediato sin demora.
  void _prewarmSessionTrack(SyncoraTrack track) {
    unawaited(() async {
      try {
        final trackDeezerId = int.tryParse(track.id) ?? track.id.hashCode.abs();
        if (_downloadedTrackDao != null && trackDeezerId > 0) {
          final downloaded = await _downloadedTrackDao.getByTrackId(trackDeezerId);
          if (downloaded != null && downloaded.downloadState == 2 && downloaded.localAudioPath.isNotEmpty) {
            return;
          }
        }
        final isConnected = _isConnectedGetter?.call() ?? true;
        if (!isConnected) return;

        String targetId = (track.youtubeVideoId != null && track.youtubeVideoId!.isNotEmpty)
            ? track.youtubeVideoId!
            : track.id;

        _log('[Session] Precalentando extracción en segundo plano para ${track.title}...');
        await _extractionService.extractUrl(
          targetId,
          trackTitle: track.title,
          trackArtist: track.artist,
          durationSeconds: track.duration?.inSeconds,
          priority: ExtractionPriority.streaming,
        );
      } catch (e) {
        _log('[Session] Precalentamiento de sesión ignorado: $e');
      }
    }());
  }

  /// Salto silencioso automático cuando se intenta reproducir una pista no
  /// descargada estando offline (Fase 6, adaptado al modelo dual en 7.A).
  ///
  /// P0.2 (bug corregido): la versión anterior llamaba a `_advance()` en
  /// cada iteración de prueba — eso consumía de verdad las colas (incluida
  /// la MANUAL, violando D-1: una pista manual sin descargar quedaba
  /// eliminada para siempre solo por probarla) y mandaba cada intento
  /// fallido al historial pese a nunca haber sonado. Ahora el bucle es de
  /// solo-lectura mientras evalúa candidatos: recorre `manualQueue` primero
  /// (D-1), luego `autoQueue`, y solo muta el estado UNA VEZ que encuentra
  /// un candidato realmente descargado, vía `_playFromQueueInternal` (que ya
  /// descarta correctamente lo anterior al índice encontrado sin tocar el
  /// historial, porque esas pistas nunca sonaron). Si ninguna cola tiene
  /// nada descargado, el estado queda "nada sonando" (`currentTrack` null)
  /// en vez de apuntar a una pista que nunca va a reproducirse.
  Future<void> _skipSilently() async {
    final evaluatedIds = <String>{};

    Future<bool> isDownloaded(SyncoraTrack track) async {
      if (_downloadedTrackDao == null) return false;
      // No repetir la consulta al DAO para el mismo id dentro de este mismo
      // bucle (ej. la misma pista agregada dos veces a la cola).
      if (!evaluatedIds.add(track.id)) return false;
      final trackDeezerId = int.tryParse(track.id) ?? track.id.hashCode.abs();
      try {
        final downloaded = await _downloadedTrackDao.getByTrackId(trackDeezerId);
        return downloaded != null && downloaded.downloadState == 2 && downloaded.localAudioPath.isNotEmpty;
      } catch (_) {
        return false;
      }
    }

    for (var i = 0; i < _state.manualQueue.length; i++) {
      if (await isDownloaded(_state.manualQueue[i])) {
        _log('[OfflineSkip] Pista manual descargada encontrada: ${_state.manualQueue[i].title}');
        await _playFromQueueInternal(QueueOrigin.manual, i);
        return;
      }
    }

    for (var i = 0; i < _state.autoQueue.length; i++) {
      if (await isDownloaded(_state.autoQueue[i])) {
        _log('[OfflineSkip] Pista automática descargada encontrada: ${_state.autoQueue[i].title}');
        await _playFromQueueInternal(QueueOrigin.auto, i);
        return;
      }
    }

    await _engine.stop();
    _state = _state.copyWith(
      clearError: true,
      clearCurrentTrack: true,
      clearCurrentOrigin: true,
    );
    _notify();
    _saveSession();
  }


  // Guard contra condiciones de carrera: si el usuario cambia de pista
  // mientras una extracción anterior sigue en curso (Fase C hizo que
  // resolver una pista sin match bueno pueda tardar bastante más — top-3
  // candidatos, cada uno con su propio ciclo de clientes/reintentos), esa
  // extracción vieja no debe pisar el motor de audio cuando por fin
  // resuelva. Cada `playCurrent()` reclama una "generación" propia al
  // entrar; solo la más reciente puede tocar `_engine` o disparar
  // `skipToNext()` por error. Sin esto, una extracción lenta y ya obsoleta
  // puede sobrescribir en silencio la pista que el usuario eligió después.
  int _playGeneration = 0;

  // ----------------------------------------------------------------------
  // Registro de historial de escucha (Fase 7.0.2)
  // ----------------------------------------------------------------------
  //
  // Mide tiempo de audio REALMENTE reproducido (no wall-clock ni
  // `position` final - inicial) sumando únicamente los avances "naturales" y
  // pequeños de `engine.position` entre actualizaciones consecutivas del
  // motor mientras está reproduciendo. Un seek (adelante o atrás) produce un
  // salto de posición mayor a `_maxNaturalPositionJump` y se ignora — así un
  // seek de 0:10 a 3:00 no suma como 2:50 de escucha real, y retroceder a
  // repetir un fragmento ya escuchado simplemente sigue sumando tiempo real
  // (no hay "doble conteo" que evitar ahí: lo que se evita es volver a
  // llamar recordEntry() para la misma instancia de reproducción una vez que
  // ya se disparó, vía `_listenRecorded`). Pausar no acumula nada porque solo
  // se suma cuando `engineState.playing` es true; reanudar continúa desde la
  // posición donde se pausó sin perder lo ya acumulado.
  static const Duration _maxNaturalPositionJump = Duration(seconds: 3);

  SyncoraTrack? _listenTrackedTrack;
  Duration _listenAccumulated = Duration.zero;
  bool _listenRecorded = false;
  Duration? _listenLastPosition;

  /// Id de la fila insertada al cruzar el umbral, para corregir después sus
  /// minutos con el tiempo realmente escuchado (ver `_finalizeListenEntry`).
  int? _listenEntryId;

  /// Debe llamarse con la pista que está a punto de empezar a sonar (o que
  /// se reinicia desde el principio), antes de tocar el motor. **Siempre**
  /// reinicia el acumulado incondicionalmente: cada llamada representa un
  /// intento de escucha nuevo (pista distinta, reinicio explícito del
  /// usuario, o una vuelta nueva de la misma pista en un loop), nunca la
  /// continuación de uno anterior. Un reintento de extracción tras un error
  /// (`_retryPolicy`) también pasa por aquí, pero como ningún audio llegó a
  /// sonar en el intento fallido, `_listenAccumulated` ya estaba en cero —
  /// reiniciar es un no-op en ese caso, no una pérdida de progreso real.
  void _beginListenTracking(SyncoraTrack newTrack) {
    // Cierra la escucha anterior antes de empezar otra: es el momento en que
    // se conoce cuánto se escuchó de verdad.
    _finalizeListenEntry();
    _listenTrackedTrack = newTrack;
    _listenAccumulated = Duration.zero;
    _listenRecorded = false;
    _listenLastPosition = null;
    _listenEntryId = null;
  }

  /// Corrige los minutos de la escucha en curso con el total real acumulado.
  ///
  /// La entrada se inserta al cruzar el umbral (≈30s) para que sobreviva a un
  /// cierre de la app, pero ahí solo se conocen esos 30s. Sin este ajuste toda
  /// canción contaba como medio minuto y el total de minutos escuchados salía
  /// muy por debajo de la realidad.
  void _finalizeListenEntry() {
    final entryId = _listenEntryId;
    final dao = _listeningHistoryDao;
    _listenEntryId = null;
    if (entryId == null || dao == null) return;
    final total = _listenAccumulated.inMilliseconds;
    unawaited(() async {
      try {
        await dao.updateListenedDuration(entryId, total);
        _onListenRecorded?.call();
      } catch (e) {
        _log('[Listen] Error ajustando la duración escuchada: $e');
      }
    }());
  }

  /// Suma al acumulado el avance natural de posición reportado por el motor
  /// y dispara el registro en cuanto se cruza el umbral D-16 (≥50% de la
  /// duración o ≥30s, lo que sea menor).
  void _trackListenProgress(AudioEngineState engineState) {
    final track = _listenTrackedTrack;
    if (track == null) {
      _listenLastPosition = null;
      return;
    }
    final newPos = engineState.position;
    if (_listenLastPosition != null && engineState.playing) {
      final delta = newPos - _listenLastPosition!;
      if (delta > Duration.zero && delta <= _maxNaturalPositionJump) {
        _listenAccumulated += delta;
      }
    }
    _listenLastPosition = newPos;

    // Se sigue acumulando DESPUÉS de registrar: `_listenRecorded` solo evita
    // insertar la escucha dos veces, no que se mida el tiempo real. Antes se
    // cortaba aquí y por eso toda pista contaba como ~30s.
    if (!_listenRecorded && _listenAccumulated >= _listenThresholdFor(track)) {
      _listenRecorded = true;
      _recordListenEntry(track, _listenAccumulated);
    }
  }

  Duration _listenThresholdFor(SyncoraTrack track) {
    const absoluteMin = Duration(seconds: 30);
    final duration = track.duration ?? Duration.zero;
    if (duration <= Duration.zero) return absoluteMin;
    final half = Duration(milliseconds: duration.inMilliseconds ~/ 2);
    return half < absoluteMin ? half : absoluteMin;
  }

  Future<void> _recordListenEntry(SyncoraTrack track, Duration accumulated) async {
    final dao = _listeningHistoryDao;
    if (dao == null) return;
    try {
      _listenEntryId = await dao.recordEntry(
        trackId: track.deezerId,
        artistId: track.artistId ?? 0,
        albumId: track.albumId ?? 0,
        durationListenedMs: accumulated.inMilliseconds,
        // Fase 7.0.3: el género no viene en el flujo normal de reproducción
        // (ni /search ni /artist/{id}/top de Deezer lo traen en DeezerTrack;
        // solo /album/{id} lo trae, y llamarlo por cada escucha sería una
        // petición extra cara y sin caché por cada canción reproducida). Se
        // propaga tal cual venga ya en la pista (hoy, en la práctica, casi
        // siempre null) en vez de forzar esa llamada — deja NULL explícito
        // y el camino abierto para cuando exista una fuente barata.
        genre: track.genre,
      );
      // Sin esto, la escucha quedaba solo en Drift hasta el siguiente arranque
      // o hasta que el usuario abriera Estadísticas EN ESE MISMO dispositivo:
      // por eso el PC no veía lo escuchado en el celular. Fire-and-forget y con
      // su propio try/catch — un fallo de red nunca debe afectar la
      // reproducción.
      try {
        _onListenRecorded?.call();
      } catch (e) {
        _log('[Listen] Error disparando sync de historial: $e');
      }
    } catch (e) {
      _log('[Listen] Error registrando escucha en el historial: $e');
    }
  }

  // ----------------------------------------------------------------------
  // Radio / cola infinita (Fase 7.B, D-10 — sin IA, solo Deezer)
  // ----------------------------------------------------------------------

  /// Revisa si corresponde generar un lote de radio y, si es así, lo dispara
  /// en segundo plano (nunca con `await` desde aquí — el llamador no debe
  /// bloquearse). No-op si no hay [_radioService] inyectado, si el toggle de
  /// Configuración está desactivado, si ya hay un fetch en curso, si
  /// `autoQueue` todavía tiene más de [_radioTriggerThreshold] pistas, o si
  /// no hay conexión (revisión: bug #5 — evita 5 peticiones condenadas de
  /// antemano en cada cambio de pista mientras el usuario está offline).
  void _maybeFetchRadio() {
    final service = _radioService;
    if (service == null) return;
    if (_isFetchingRadio) return;
    if (!(_radioEnabledGetter?.call() ?? true)) return;
    if (_state.autoQueue.length > _radioTriggerThreshold) return;
    if (_isConnectedGetter?.call() == false) return;

    _isFetchingRadio = true;
    // Snapshot de la "sesión de contexto" en el momento del disparo (ver
    // _fetchRadioBatch): si el usuario cambia de contexto antes de que
    // resuelva, el resultado se descarta en silencio para no anexar un lote
    // que ya no corresponde. Revisión (bug #1): NO se usa `activeContextId`
    // para esto — la mayoría de los `setQueue()` de la app (búsqueda,
    // inicio, artista, track_tile) lo pasan en `null`, así que comparar
    // `activeContextId` no detectaba nada en el caso común (`null != null`
    // siempre es falso). `_contextGeneration` sí cambia en cada `setQueue()`
    // tenga o no `activeContextId`.
    final requestGeneration = _contextGeneration;
    final contextTracks = _state.originalContextTracks;
    final excludeIds = <String>{
      ..._state.manualQueue.map((t) => t.id),
      ..._state.autoQueue.map((t) => t.id),
      ..._state.originalContextTracks.map((t) => t.id),
      // Revisión (bug #2): faltaba el historial — sin esto la radio podía
      // reofrecer una pista que el usuario ya escuchó y dejó atrás.
      ..._state.history.map((h) => h.track.id),
      if (_state.currentTrack != null) _state.currentTrack!.id,
    };

    unawaited(_fetchRadioBatch(
      service: service,
      contextTracks: contextTracks,
      excludeIds: excludeIds,
      requestGeneration: requestGeneration,
    ));
  }

  /// Genera el lote de radio con I/O real y lo anexa al final de
  /// `autoQueue` (nunca toca `manualQueue`, nunca interrumpe la
  /// reproducción). Un fallo de red aquí nunca debe afectar la reproducción
  /// en curso — se registra con `_log(...)` y no se relanza.
  Future<void> _fetchRadioBatch({
    required RadioService service,
    required List<SyncoraTrack> contextTracks,
    required Set<String> excludeIds,
    required int requestGeneration,
  }) async {
    try {
      final batch = await service.generateBatch(
        contextTracks: contextTracks,
        excludeIds: excludeIds,
      );
      if (_disposed || batch.isEmpty) return;

      // Condición de carrera del modelo de cola dual: si por el tiempo que
      // tardó el fetch el usuario ya arrancó una sesión de contexto nueva
      // (otro setQueue(), con o sin activeContextId), este lote ya no
      // corresponde a la petición que lo originó — se descarta en silencio.
      // Avanzar dentro del MISMO contexto (siguiente pista de la misma
      // playlist, _advance()/_retreat()/playFromQueue()) NO incrementa
      // _contextGeneration, así que el lote sigue siendo válido en ese caso.
      if (_contextGeneration != requestGeneration) {
        _log('[Radio] Lote descartado: el usuario ya inició una sesión de contexto nueva.');
        return;
      }

      final updatedAuto = List<SyncoraTrack>.from(_state.autoQueue)..addAll(batch);
      _state = _state.copyWith(autoQueue: List.unmodifiable(updatedAuto));
      _log('[Radio] ${batch.length} pistas de radio añadidas a la cola automática.');
      _notify();
      _saveSession();
    } catch (e) {
      _log('[Radio] Error generando lote de radio: $e');
    } finally {
      _isFetchingRadio = false;
    }
  }

  // ----------------------------------------------------------------------
  // Crossfade PREVENTIVO (Fase 7.D, rediseño post-revisión de código)
  // ----------------------------------------------------------------------
  //
  // El diseño original solo podía disparar un crossfade si el usuario
  // saltaba a mano ("siguiente") mientras la pista actual seguía sonando —
  // nunca en el flujo natural de una playlist, que es el caso de uso
  // principal (dejar sonar un álbum completo). Causa raíz: la condición
  // "el motor está reproduciendo algo" se evaluaba DESPUÉS de que la pista
  // llegara a su fin natural (`_onComplete()` → `skipToNext()` →
  // `_playCurrentInternal()`), momento en el que el motor ya reporta
  // `playing: false` y, aunque no lo reportara, ya no queda audio de la
  // pista saliente que desvanecer — un crossfade real tiene que EMPEZAR
  // antes del final, no reaccionar después.
  //
  // Esto se resuelve monitoreando la posición en cada tick de
  // `_onEngineState` (`_maybeCrossfadeProactively`) y disparando la
  // transición en cuanto el tiempo restante de la pista actual cae por
  // debajo de la duración configurada — sin esperar a que el usuario haga
  // nada. El camino de skip MANUAL (usuario toca "siguiente" con tiempo de
  // sobra) sigue funcionando exactamente igual que antes, en
  // `_playCurrentInternal`, con la duración configurada completa.

  /// Revisa en cada tick de posición si corresponde disparar un crossfade
  /// PREVENTIVO: la pista actual es local (Pitfall #17), hay crossfade
  /// configurado (> 0), el motor está reproduciendo, y el tiempo restante
  /// de la pista actual ya cayó por debajo (o igual) de esa duración.
  void _maybeCrossfadeProactively(AudioEngineState engineState) {
    final current = _state.currentTrack;
    if (current == null) return;
    // Guard sincrónico primero que nada: mientras haya un crossfade en
    // vuelo, los ticks que llegan no son confiables como "tiempo restante de
    // la pista actual" (pueden venir del motor saliente, o del entrante con
    // una posición vieja todavía sin actualizar) — ver docstring de
    // [_isCrossfading].
    if (_isCrossfading) return;
    // Una transición iniciada por el usuario (o por la cascada de error) ya
    // está decidiendo qué suena a continuación: no arrancar un crossfade
    // preventivo en paralelo con ella.
    if (_isTransitioning) return;
    if (_crossfadeAttemptedForTrackId == current.id) return; // ya se intentó para esta pista
    if (!_currentPlaybackIsLocal) return; // Pitfall #17: nunca desde streaming
    if (!engineState.playing) return;
    // Con repeat-one la pista se vuelve a reproducir entera (`_onComplete`):
    // avanzar de cola con un crossfade preventivo rompería ese modo.
    if (_state.repeatMode == SyncoraRepeatMode.one) return;

    final crossfadeDuration = _crossfadeDurationGetter?.call() ?? Duration.zero;
    if (crossfadeDuration <= Duration.zero) return; // setting "off"
    if (engineState.duration <= Duration.zero) return; // duración aún desconocida

    final remaining = engineState.duration - engineState.position;
    if (remaining > crossfadeDuration || remaining <= Duration.zero) return;

    final peeked = _peekNext();
    if (peeked == null) return;
    final (nextTrack, nextOrigin) = peeked;

    // Síncrono, ANTES de cualquier `await`: evita que el próximo tick de
    // posición (que puede llegar antes de que resuelva el chequeo async de
    // descarga de abajo) dispare un segundo intento en paralelo para la
    // MISMA pista.
    _crossfadeAttemptedForTrackId = current.id;
    _isCrossfading = true;
    final fadeGen = ++_crossfadeGeneration;

    // La duración real del fade es el mínimo entre la configurada y lo que
    // en verdad queda de la pista saliente en este instante — así el fade
    // termina justo cuando la pista vieja habría terminado de forma
    // natural, sin que el motor saliente llegue a su propio EOF a mitad
    // del fade (lo que dispararía una completion espuria).
    final actualFadeDuration = remaining < crossfadeDuration ? remaining : crossfadeDuration;

    unawaited(_runProactiveCrossfade(current.id, nextTrack, nextOrigin, actualFadeDuration, fadeGen));
  }

  /// Libera [_isCrossfading] solo si [fadeGen] sigue siendo la generación
  /// vigente — ver docstring de [_crossfadeGeneration].
  void _releaseCrossfadeGuard(int fadeGen) {
    if (_disposed) return;
    if (fadeGen != _crossfadeGeneration) return;
    _isCrossfading = false;
  }

  /// Invalida cualquier crossfade en curso (y su liberación diferida del
  /// guard) porque otra cosa acaba de tomar el control de qué suena: un skip
  /// manual, `playFromQueue`, `setQueue`, la cascada de auto-skip, etc.
  void _abandonCrossfadeGuard() {
    _crossfadeGeneration++;
    _isCrossfading = false;
  }

  /// Ejecuta el intento de crossfade preventivo ya decidido por
  /// [_maybeCrossfadeProactively]: verifica que la pista siguiente esté
  /// descargada localmente (guard 7.D.4, mismo chequeo al
  /// `DownloadedTrackDao` que usa `_playCurrentInternal`) y, si lo está,
  /// confirma el avance en el estado y dispara la transición real en el
  /// motor.
  Future<void> _runProactiveCrossfade(
    String triggeringTrackId,
    SyncoraTrack nextTrack,
    QueueOrigin nextOrigin,
    Duration fadeDuration,
    int fadeGen,
  ) async {
    // Se pone en `true` solo cuando el motor ya se comprometió con la
    // transición: a partir de ahí el guard NO se libera de inmediato sino
    // recién cuando el ramp de volumen debería haber terminado (ver más
    // abajo). En cualquier otro camino de salida (siguiente no descargada,
    // intento obsoleto, excepción antes de llamar al motor) se libera ya
    // mismo — si no, un solo intento fallido dejaría el crossfade preventivo
    // apagado para el resto de la sesión.
    var engineHandoffStarted = false;
    // Mismo punto de disparo de radio/cola infinita (Fase 7.B) que
    // `playCurrent()` — este camino también consume de `autoQueue` (vía
    // `_commitAdvanceTo`) si termina avanzando, así que debe revisar igual
    // si corresponde rellenarla. `finally` para cubrir todos los caminos de
    // retorno (siguiente no descargada, intento obsoleto, éxito).
    try {
      final trackDeezerId = int.tryParse(nextTrack.id) ?? nextTrack.id.hashCode.abs();
      DownloadedTrack? downloaded;
      if (_downloadedTrackDao != null && trackDeezerId > 0) {
        try {
          downloaded = await _downloadedTrackDao.getByTrackId(trackDeezerId);
        } catch (e) {
          _log('[Crossfade] Error verificando descarga local de la siguiente pista: $e');
        }
      }

      // Si mientras se resolvía el chequeo de descarga la pista actual ya
      // cambió por otra vía (skip manual, error del motor, etc.), este
      // intento quedó obsoleto — no debe pisar lo que sea que esté sonando
      // ahora.
      if (_state.currentTrack?.id != triggeringTrackId) return;

      final nextIsLocal =
          downloaded != null && downloaded.downloadState == 2 && downloaded.localAudioPath.isNotEmpty;
      if (!nextIsLocal) return; // 7.D.4: sin descarga no hay crossfade

      // Confirma el avance en el estado (por id, no por posición — pueden
      // haber pasado varios ticks desde el peek original si el chequeo de
      // descarga tardó) y dispara la transición real. `crossfadeToLocalSource`
      // ya resuelve rápido (el swap interno del motor ocurre de inmediato al
      // arrancar el fade, no al terminar el ramp de volumen), así que esto
      // no bloquea al usuario por toda la duración del fade.
      _commitAdvanceTo(nextTrack, nextOrigin);
      _beginListenTracking(nextTrack);
      _onPlaybackStartedSuccessfully();
      _currentPlaybackIsLocal = true;
      _notify();
      _saveSession();

      final localPath = downloaded.localAudioPath;
      _log('[Crossfade] Preventivo (${fadeDuration.inMilliseconds}ms) hacia pista local: $localPath');
      engineHandoffStarted = true;
      try {
        await _engine.crossfadeToLocalSource(localPath, fadeDuration);
      } catch (e) {
        // Si el motor falló, no hay ningún ramp corriendo que esperar: el
        // swap interno ocurre DESPUÉS de cargar y arrancar el entrante, así
        // que el que sigue sonando es el saliente y su EOF natural (a
        // segundos de acá) es lo único que puede reanudar la reproducción.
        // Diferir la liberación del guard se comería justo esa completion y
        // dejaría el reproductor mudo.
        _releaseCrossfadeGuard(fadeGen);
        _log('[Crossfade] Falló el crossfade preventivo hacia $localPath: $e');
        return;
      }
      unawaited(
        Future<void>.delayed(fadeDuration + _crossfadeSettleMargin)
            .then((_) => _releaseCrossfadeGuard(fadeGen)),
      );
      _saveSession();
    } finally {
      if (!engineHandoffStarted) _releaseCrossfadeGuard(fadeGen);
      _maybeFetchRadio();
    }
  }

  /// Núcleo: resuelve la URL de la pista actual o carga el archivo local si está descargado.
  ///
  /// Punto de disparo de radio/cola infinita (Fase 7.B): al final de este
  /// método (vía `finally`, para cubrir TODOS sus caminos de retorno —
  /// descarga local, error de extracción, éxito) se revisa si `autoQueue`
  /// quedó en `_radioTriggerThreshold` pistas o menos y, si es así, se
  /// dispara `_maybeFetchRadio()` SIN esperarlo: nunca debe bloquear la
  /// reproducción en curso.
  Future<void> playCurrent() async {
    final track = _state.currentTrack;
    if (track == null) return;

    try {
      await _playCurrentInternal(track);
    } finally {
      _maybeFetchRadio();
    }
  }

  Future<void> _playCurrentInternal(SyncoraTrack track) async {
    _beginListenTracking(track);

    final myGeneration = ++_playGeneration;
    bool isStale() => myGeneration != _playGeneration;

    // Este camino (skip manual, playFromQueue, setQueue, reintentos, cascada
    // de auto-skip) toma el control de qué suena: cualquier crossfade
    // preventivo anterior deja de ser dueño del guard, así el usuario nunca
    // queda con el crossfade preventivo bloqueado por una transición vieja.
    _abandonCrossfadeGuard();

    final crossfadeDuration = _crossfadeDurationGetter?.call() ?? Duration.zero;
    final previousPlaybackWasLocal = _currentPlaybackIsLocal;
    final wasEnginePlaying = _state.engine.playing;
    // Revisión de código: resetear explícitamente al principio de CADA
    // intento de reproducción, no solo actualizarlo en los caminos de
    // éxito de más abajo — si este intento falla o cae en un camino que no
    // lo toca explícitamente (ej. ExtractionFailure), no debe quedar con
    // el valor de una pista N-2 que ya no representa lo que el motor está
    // haciendo ahora.
    _currentPlaybackIsLocal = false;

    final trackDeezerId = int.tryParse(track.id) ?? track.id.hashCode.abs();

    // 1. Verificar si existe descarga local (state == 2) — se resuelve ANTES
    // del stop()/micro fade-out incondicional para poder decidir si
    // corresponde crossfade (condición 2: la pista NUEVA está descargada).
    DownloadedTrack? downloaded;
    if (_downloadedTrackDao != null && trackDeezerId > 0) {
      try {
        downloaded = await _downloadedTrackDao.getByTrackId(trackDeezerId);
      } catch (e) {
        _log('[Play] Error verificando descarga local: $e');
      }
    }
    if (isStale()) return;

    final newTrackIsLocal =
        downloaded != null && downloaded.downloadState == 2 && downloaded.localAudioPath.isNotEmpty;

    // Fase 7.D (crossfade): las 4 condiciones para cruzar (ver docstring de
    // `_maybeCrossfadeProactively`). Si no se cumplen, se detiene el motor
    // previo con micro fade-out para evitar clics/pops.
    final useCrossfade = crossfadeDuration > Duration.zero &&
        newTrackIsLocal &&
        previousPlaybackWasLocal &&
        wasEnginePlaying;

    if (!useCrossfade) {
      await _microFadeOut();
      await _engine.stop();
    }

    // 2. Pista descargada localmente: cargar directo, sin pasar por el ExtractionIsolate
    if (newTrackIsLocal) {
      final localPath = downloaded.localAudioPath;
      _onPlaybackStartedSuccessfully();
      _currentPlaybackIsLocal = true;

      final initialPos = (_restoredPositionSeconds != null && _restoredPositionSeconds! > 0)
          ? Duration(seconds: _restoredPositionSeconds!)
          : null;
      _restoredPositionSeconds = null;
      _restoredPositionTrackId = null;

      if (useCrossfade) {
        _log('[Play] Crossfade a descarga local: $localPath (${crossfadeDuration.inSeconds}s)');
        await _engine.crossfadeToLocalSource(localPath, crossfadeDuration);
      } else {
        _log('[Play] Pista local descargada encontrada: $localPath. Cargando sin pasar por ExtractionIsolate.');
        await _engine.setLocalSource(localPath, initialPosition: initialPos);

        if (initialPos != null) {
          await _engine.seek(initialPos);
        }

        await _engine.play();
      }
      _saveSession();
      return;
    }

    // 3. Sin descarga local: verificar conectividad a internet
    final isConnected = _isConnectedGetter?.call() ?? true;
    if (!isConnected) {
      _log('[Play] Sin conexión y la canción no está descargada: ejecutando salto silencioso.');
      await _skipSilently();
      return;
    }

    // 4. Flujo normal de extracción de YouTube
    String targetId = (track.youtubeVideoId != null && track.youtubeVideoId!.isNotEmpty)
        ? track.youtubeVideoId!
        : track.id;

    _log('[Play] Resolviendo extracción de YouTube para ${track.title} ($targetId)');
    final result = await _extractionService.extractUrl(
      targetId,
      trackTitle: track.title,
      trackArtist: track.artist,
      durationSeconds: track.duration?.inSeconds,
      priority: ExtractionPriority.streaming,
    );

    if (isStale()) {
      _log('[Play] Resultado de extracción descartado (ya no es la pista activa): ${track.title}');
      return;
    }

    switch (result) {
      case ExtractionSuccess(:final streamUrl, :final headers):
        _log('[Play] URL resuelta, cargando en el motor...');
        _retryPolicy.reset(track.id); // extracción exitosa: resetear contador
        _onPlaybackStartedSuccessfully();
        // Fase 7.D (condición 3 del crossfade): esta pista arranca desde
        // streaming, no desde descarga local — la próxima vez que se llegue
        // aquí para la SIGUIENTE pista, este flag debe reflejar que la
        // actual no califica como origen local para un crossfade.
        _currentPlaybackIsLocal = false;
        try {
          final initialPos = (_restoredPositionSeconds != null && _restoredPositionSeconds! > 0)
              ? Duration(seconds: _restoredPositionSeconds!)
              : null;
          _restoredPositionSeconds = null;
          _restoredPositionTrackId = null;

          await _engine.setUrl(streamUrl, headers: headers, initialPosition: initialPos);

          // Si había una posición restaurada al iniciar la app, buscarla
          if (initialPos != null) {
            await _engine.seek(initialPos);
          }

          await _engine.play();
          _saveSession();
        } catch (e) {
          _log('[Play] Error cargando en motor: $e');
          _state = _state.copyWith(
            lastError: ExtractionError.unknownError,
            lastErrorMessage: 'No se pudo iniciar la reproducción: $e',
          );
          _notify();
        }
        break;

      case ExtractionFailure(:final error, :final message):
        await _handleExtractionError(track, error, message);
        break;
    }
  }

  Future<void> _handleExtractionError(
    SyncoraTrack track,
    ExtractionError error,
    String? message,
  ) async {
    _log('[Play] Error $error: $message');

    if (error == ExtractionError.cancelled) {
      _log('[Play] Petición previa cancelada por superposición: omitiendo.');
      return;
    }

    if (error == ExtractionError.notFound || error == ExtractionError.unknownError) {
      _consecutiveLogicalFailures++;
      // 7.C.2 (D-21): marcado de sesión, nunca persistido — nueva instancia
      // de Set, nunca mutación in-place (mismo patrón que las colas).
      final updatedUnavailable = Set<String>.from(_state.unavailableTrackIds)..add(track.id);

      if (_consecutiveLogicalFailures >= _cascadeGuardThreshold) {
        // 7.C.3: guard de cascada — NO se llama a _advanceAndPlay() de
        // nuevo (eso seguiría saltando pistas rotas en silencio). Se
        // pausa el motor, igual que el guard 403/red, y se deja un aviso
        // resumen para que la UI ofrezca continuar o pausar.
        _log('[Play] Guard de cascada: $_consecutiveLogicalFailures fallos lógicos seguidos '
            '— deteniendo auto-skip.');
        await _engine.pause();
        _state = _state.copyWith(
          lastError: error,
          lastErrorMessage: message,
          unavailableTrackIds: Set.unmodifiable(updatedUnavailable),
          notice: _nextNotice(
            kind: PlayerNoticeKind.cascadeGuard,
            message: 'Varias canciones seguidas no están disponibles. '
                'Auto-skip detenido.',
          ),
        );
        _notify();
        _saveSession();
        return;
      }

      _state = _state.copyWith(
        lastError: error,
        lastErrorMessage: message,
        unavailableTrackIds: Set.unmodifiable(updatedUnavailable),
        notice: _nextNotice(
          kind: PlayerNoticeKind.logicalSkip,
          message: '${track.title} no disponible — saltada',
          trackTitle: track.title,
        ),
      );
      _notify();
      // Cascada interna (posiblemente ya anidada dentro de un skipToNext()
      // guardado) — usa el núcleo sin guard, ver _advanceAndPlay().
      await _advanceAndPlay();
      return;
    }

    final canRetry = _retryPolicy.canRetry(track.id, error);
    if (canRetry) {
      _log('[Play] Reintentando (intento ${_retryPolicy.getAttemptCount(track.id)})...');
      await playCurrent();
      return;
    }

    _log('[Play] Pausa inmediata por $error persistente (guard 403).');
    await _engine.pause();
    final resolvedMessage = message ?? 'Reproducción pausada por error persistente.';
    _state = _state.copyWith(
      lastError: error,
      lastErrorMessage: resolvedMessage,
      // H-6: la pausa por 403/red persistente ya funcionaba desde la Fase 1,
      // pero el aviso visual que la acompaña nunca llegó a conectarse a
      // ningún widget — cablear el mismo mecanismo de `notice` que 7.C usa
      // para el toast de auto-skip lógico, con su propio tipo (nunca dice
      // "no disponible — saltada": acá no hubo skip, solo una pausa).
      notice: _nextNotice(
        kind: PlayerNoticeKind.persistentError,
        message: resolvedMessage,
      ),
    );
    _notify();
    _saveSession();
  }

  void _onEngineState(AudioEngineState engineState) {
    final wasError = _state.engine.processingState == AudioProcessingState.error;
    final isNowError = engineState.processingState == AudioProcessingState.error;

    _trackListenProgress(engineState);

    _state = _state.copyWith(engine: _withRestoredPosition(engineState));
    _notify();

    _maybeSavePositionPeriodically();

    // Fase 7.D (rediseño): revisa en cada tick si corresponde disparar un
    // crossfade preventivo antes de que la pista actual llegue a su fin
    // natural — ver docstring de `_maybeCrossfadeProactively`.
    _maybeCrossfadeProactively(engineState);

    // El motor nativo puede reportar un error de reproducción sin pasar por
    // ExtractionFailure (ej. MediaKitEngine detecta un EOF sin haber sonado
    // nada real — stream roto/403 — y lo traduce a `error`; JustAudioEngine
    // lo hace ante cualquier excepción de ExoPlayer). Antes nada escuchaba
    // esta transición: en Android el reproductor se quedaba trabado en
    // `error` sin avanzar; en Windows dependía por completo de que el propio
    // motor mintiera con `completed` para no trabarse. Solo reacciona en la
    // transición (no en cada re-emisión) para no disparar `skipToNext()` en
    // bucle.
    if (isNowError && !wasError) {
      _log('[Play] El motor de audio reportó un error de reproducción — saltando a la siguiente pista.');
      _state = _state.copyWith(
        lastError: ExtractionError.unknownError,
        lastErrorMessage: 'El motor de audio no pudo reproducir esta pista.',
      );
      _notify();
      // Puede dispararse mientras un skipToNext()/playFromQueue() guardado
      // ya está en curso (ej. el motor reporta error justo al cargar la
      // pista nueva) — usa el núcleo sin guard, igual que en
      // _handleExtractionError.
      _advanceAndPlay();
    }
  }

  /// Mantiene la posición restaurada visible en la barra hasta que la
  /// reproducción arranque de verdad.
  ///
  /// `_restoreSession` deja la posición guardada en el estado, pero el motor
  /// sigue emitiendo su propio estado en reposo (posición 0, sin reproducir)
  /// y el tick siguiente la pisaba: por eso la barra "aparecía en el segundo
  /// 0" aunque al pulsar Play el audio sí arrancara donde el usuario lo
  /// dejó (eso lo resuelve `_restoredPositionSeconds` en `playCurrent`).
  ///
  /// La ventana no puede filtrarse a la pista siguiente: está atada al id de
  /// la pista dueña ([_restoredPositionTrackId]) y solo aplica mientras el
  /// motor reporte posición 0 y no esté reproduciendo. En cuanto suena algo,
  /// deja de aplicarse sola — no hay bandera que limpiar (§2.3 de
  /// `correcciones_qa_post_fase_7.md`).
  AudioEngineState _withRestoredPosition(AudioEngineState engineState) {
    final pending = _restoredPositionSeconds;
    if (pending == null || pending <= 0) return engineState;
    if (_restoredPositionTrackId == null) return engineState;
    if (_state.currentTrack?.id != _restoredPositionTrackId) return engineState;
    if (engineState.playing || engineState.position != Duration.zero) {
      return engineState;
    }
    return engineState.copyWith(position: Duration(seconds: pending));
  }

  /// Persiste la sesión cada [_periodicSessionSaveInterval] mientras suena
  /// algo, para que cerrar la app en medio de una canción no guarde la
  /// posición del último evento discreto (normalmente el segundo 0).
  ///
  /// No escribe en el motor de audio ni programa temporizadores propios: se
  /// engancha al tick que el motor ya emite. La escritura en disco es
  /// atómica y single-flight (ver `PlayerSessionStorage`), así que subir la
  /// frecuencia no puede corromper el archivo.
  void _maybeSavePositionPeriodically() {
    if (!_state.engine.playing) return;
    final now = DateTime.now();
    final last = _lastPeriodicSessionSave;
    if (last != null && now.difference(last) < _periodicSessionSaveInterval) {
      return;
    }
    _lastPeriodicSessionSave = now;
    _saveSession();
  }

  Future<void> _onComplete() async {
    // Completar naturalmente implica haber sonado el 100% de la pista, así
    // que en la inmensa mayoría de los casos el umbral D-16 ya se cruzó
    // durante `_trackListenProgress` (llamado en cada tick de posición). Esta
    // llamada extra es una red de seguridad para pistas muy cortas o motores
    // que no emiten un último tick de posición justo antes de completar —
    // por eso lee `_engine.position` en vivo en vez de reutilizar
    // `_state.engine` (que ya fue procesado por el último tick y no
    // capturaría nada nuevo).
    _trackListenProgress(_state.engine.copyWith(position: _engine.position));

    // Con un crossfade en curso, el avance de cola YA se hizo al arrancar el
    // fade: la única completion que puede llegar acá es la del motor
    // saliente terminando su propia pista (normalmente el wrapper ya no
    // escucha sus streams, pero hay una ventana entre `_commitAdvanceTo` y
    // el swap interno del motor en la que sí). Atenderla dispararía un
    // segundo avance para la misma transición — parte de la cascada de
    // "saltó 6 canciones" del reporte de pruebas manuales.
    if (_isCrossfading) {
      _log('[Crossfade] Fin de pista ignorado: llegó del motor saliente con un crossfade en curso.');
      return;
    }

    if (_state.repeatMode == SyncoraRepeatMode.one) {
      // Repetir es una vuelta nueva, no la continuación de la anterior — sin
      // esto, una pista en repeat-one solo se registraba en su primera
      // vuelta (Fase 7.0 — hallazgo de revisión).
      final current = _state.currentTrack;
      if (current != null) _beginListenTracking(current);
      await _engine.seek(Duration.zero);
      await _engine.play();
      return;
    }
    await skipToNext();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  void _log(String msg) {
    // `dev.log` es lo que efectivamente aparece en la consola/DevTools que
    // se está usando para depurar — `_logController` no tiene ningún
    // suscriptor en la app hoy, así que sin esto los mensajes de este
    // controlador (y los del motor de audio, reenviados vía `logStream`)
    // eran invisibles en la práctica, a diferencia de los `[JS] ...` del
    // isolate de extracción, que sí llaman a `dev.log` directamente.
    dev.log(msg, name: 'SyncoraPlayer');
    if (!_logController.isClosed) _logController.add(msg);

    // `MediaKitEngine` puede apagar Skip Silence por su cuenta si libmpv
    // rechaza el filtro `af` (ver docstring de `_applySilenceFilter`) — sin
    // este chequeo, `_state.skipSilence` se queda en `true` para siempre y
    // el toggle de Configuración sigue mostrando "activado" aunque el motor
    // ya lo haya desactivado internamente. No requiere cambiar el contrato
    // de `AudioEngine`: se apoya en el `logStream` que ya existía.
    if (msg.contains('[SkipSilenceAutoDisabled]') && _state.skipSilence) {
      _state = _state.copyWith(skipSilence: false);
      _notify();
    }
  }

  @override
  void dispose() {
    // Última oportunidad de registrar la escucha en curso si ya cruzó el
    // umbral antes de que se cierre la app/controlador. Lee la posición en
    // vivo (ver `_onComplete`) para que esto sea una red de seguridad real.
    _trackListenProgress(_state.engine.copyWith(position: _engine.position));
    // Cierra la escucha en curso con el tiempo real antes de irse: si no, se
    // quedaría guardada con los ~30s del umbral.
    _finalizeListenEntry();
    _disposed = true;
    _engineSub?.cancel();
    _completionSub?.cancel();
    _engineLogSub?.cancel();
    _logController.close();
    _engine.dispose();
    super.dispose();
  }
}
