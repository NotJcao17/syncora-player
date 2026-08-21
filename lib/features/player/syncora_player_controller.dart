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
  })  : _engine = engine, // ignore: prefer_initializing_formals
        _extractionService = extractionService, // ignore: prefer_initializing_formals
        _deezerApi = deezerApi, // ignore: prefer_initializing_formals
        _downloadedTrackDao = downloadedTrackDao,
        _listeningHistoryDao = listeningHistoryDao,
        _radioService = radioService,
        _isConnectedGetter = isConnectedGetter,
        _radioEnabledGetter = radioEnabledGetter;

  final AudioEngine _engine;
  final ExtractionService _extractionService;
  final DeezerApi? _deezerApi;
  final DownloadedTrackDao? _downloadedTrackDao;
  final ListeningHistoryDao? _listeningHistoryDao;
  final RadioService? _radioService;
  final bool Function()? _isConnectedGetter;
  final bool Function()? _radioEnabledGetter;
  final RetryPolicy _retryPolicy = RetryPolicy();
  final PlayerSessionStorage _sessionStorage = PlayerSessionStorage();

  /// Cupo máximo de la pila de historial (D-3).
  static const int _historyCap = 50;

  /// Umbral de disparo de radio/cola infinita (Fase 7.B, D-10): cuando
  /// `autoQueue` baja a esta cantidad de pistas o menos, se genera un lote
  /// nuevo en segundo plano.
  static const int _radioTriggerThreshold = 5;

  /// Evita disparar fetches de radio concurrentes (Fase 7.B).
  bool _isFetchingRadio = false;

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
    try {
      await _advanceAndPlay();
    } finally {
      _isTransitioning = false;
    }
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

  /// Micro fade-out de audio (150ms) antes de cambiar de pista o detener el motor
  Future<void> _microFadeOut() async {
    if (!_state.engine.playing || _isTestEnv) return;
    try {
      final currentVol = _state.engine.volume;
      if (currentVol <= 0) return;
      final step = currentVol / 3.0;
      await _engine.setVolume((currentVol - step).clamp(0.0, 1.0));
      await Future.delayed(const Duration(milliseconds: 50));
      await _engine.setVolume((currentVol - 2 * step).clamp(0.0, 1.0));
      await Future.delayed(const Duration(milliseconds: 50));
      await _engine.setVolume(0.0);
      await Future.delayed(const Duration(milliseconds: 50));
      await _engine.setVolume(currentVol);
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

  /// Vacía ambas colas (manual y automática) Y `originalContextTracks` —
  /// sin esto último, un repeat-all posterior "resucitaría" el contexto que
  /// el usuario acaba de limpiar explícitamente (P0.4). No toca
  /// `currentTrack` ni el historial.
  void clearQueue() {
    _state = _state.copyWith(
      manualQueue: const [],
      autoQueue: const [],
      originalContextTracks: const [],
    );
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
    SyncoraTrack? next;
    QueueOrigin? nextOrigin;

    if (_state.manualQueue.isNotEmpty) {
      next = _state.manualQueue.first;
      nextOrigin = QueueOrigin.manual;
    } else if (_state.autoQueue.isNotEmpty) {
      next = _state.autoQueue.first;
      nextOrigin = QueueOrigin.auto;
    } else if (_state.repeatMode == SyncoraRepeatMode.all && _state.originalContextTracks.isNotEmpty) {
      final regenerated = List<SyncoraTrack>.from(_state.originalContextTracks);
      if (_state.shuffle) regenerated.shuffle();
      _state = _state.copyWith(autoQueue: List.unmodifiable(regenerated));
      if (_state.autoQueue.isNotEmpty) {
        next = _state.autoQueue.first;
        nextOrigin = QueueOrigin.auto;
      }
    }

    if (next == null || nextOrigin == null) return false;

    final newHistory = _pushHistory(_state.history, _state.currentTrack, _state.currentOrigin);

    List<SyncoraTrack> newManual = _state.manualQueue;
    List<SyncoraTrack> newAuto = _state.autoQueue;
    if (nextOrigin == QueueOrigin.manual) {
      newManual = List<SyncoraTrack>.from(_state.manualQueue)..removeAt(0);
    } else {
      newAuto = List<SyncoraTrack>.from(_state.autoQueue)..removeAt(0);
    }

    _state = _state.copyWith(
      currentTrack: next,
      currentOrigin: nextOrigin,
      manualQueue: List.unmodifiable(newManual),
      autoQueue: List.unmodifiable(newAuto),
      history: List.unmodifiable(newHistory),
      clearError: true,
    );
    return true;
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

  int _lastSavedPositionSeconds = -1;

  void _saveSession() {
    _sessionStorage.saveSession(
      currentTrack: _state.currentTrack,
      currentOrigin: _state.currentOrigin,
      manualQueue: _state.manualQueue,
      autoQueue: _state.autoQueue,
      originalContextTracks: _state.originalContextTracks,
      history: _state.history,
      positionSeconds: _state.engine.position.inSeconds,
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
        playing: false,
        processingState: AudioProcessingState.idle,
      ),
      clearError: true,
    );
    _notify();
    _log('[Session] Sesión restaurada: ${session.manualQueue.length + session.autoQueue.length} '
        'pistas en cola, posición: ${session.positionSeconds}s (pausado)');
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
    _state = _state.copyWith(clearError: true, clearCurrentTrack: true, clearCurrentOrigin: true);
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
    _listenTrackedTrack = newTrack;
    _listenAccumulated = Duration.zero;
    _listenRecorded = false;
    _listenLastPosition = null;
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
    if (_listenRecorded) return;

    final newPos = engineState.position;
    if (_listenLastPosition != null && engineState.playing) {
      final delta = newPos - _listenLastPosition!;
      if (delta > Duration.zero && delta <= _maxNaturalPositionJump) {
        _listenAccumulated += delta;
      }
    }
    _listenLastPosition = newPos;

    if (_listenAccumulated >= _listenThresholdFor(track)) {
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
      await dao.recordEntry(
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

    // Detener inmediatamente cualquier audio previo con micro fade-out para evitar audio bleed/clics
    await _microFadeOut();
    await _engine.stop();

    final trackDeezerId = int.tryParse(track.id) ?? track.id.hashCode.abs();

    // 1. Verificar si existe descarga local (state == 2)
    if (_downloadedTrackDao != null && trackDeezerId > 0) {
      try {
        final downloaded = await _downloadedTrackDao.getByTrackId(trackDeezerId);
        if (isStale()) return;
        if (downloaded != null && downloaded.downloadState == 2 && downloaded.localAudioPath.isNotEmpty) {
          _log('[Play] Pista local descargada encontrada: ${downloaded.localAudioPath}. Cargando sin pasar por ExtractionIsolate.');
          await _engine.setLocalSource(downloaded.localAudioPath);

          if (_restoredPositionSeconds != null && _restoredPositionSeconds! > 0) {
            final targetPos = Duration(seconds: _restoredPositionSeconds!);
            _restoredPositionSeconds = null;
            await _engine.seek(targetPos);
          }

          await _engine.play();
          _saveSession();
          return;
        }
      } catch (e) {
        _log('[Play] Error verificando descarga local: $e');
      }
    }

    // 2. Sin descarga local: verificar conectividad a internet
    final isConnected = _isConnectedGetter?.call() ?? true;
    if (!isConnected) {
      _log('[Play] Sin conexión y la canción no está descargada: ejecutando salto silencioso.');
      await _skipSilently();
      return;
    }

    // 3. Flujo normal de extracción de YouTube
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
        try {
          await _engine.setUrl(streamUrl, headers: headers);

          // Si había una posición restaurada al iniciar la app, buscarla
          if (_restoredPositionSeconds != null && _restoredPositionSeconds! > 0) {
            final targetPos = Duration(seconds: _restoredPositionSeconds!);
            _restoredPositionSeconds = null;
            await _engine.seek(targetPos);
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
      _state = _state.copyWith(
        lastError: error,
        lastErrorMessage: message,
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
    _state = _state.copyWith(
      lastError: error,
      lastErrorMessage: message ?? 'Reproducción pausada por error persistente.',
    );
    _notify();
    _saveSession();
  }

  void _onEngineState(AudioEngineState engineState) {
    final wasError = _state.engine.processingState == AudioProcessingState.error;
    final isNowError = engineState.processingState == AudioProcessingState.error;

    _trackListenProgress(engineState);

    _state = _state.copyWith(engine: engineState);
    _notify();

    final currentPosSec = engineState.position.inSeconds;
    if (currentPosSec != _lastSavedPositionSeconds && (currentPosSec % 2 == 0 || !engineState.playing)) {
      _lastSavedPositionSeconds = currentPosSec;
      _saveSession();
    }

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
  }

  @override
  void dispose() {
    // Última oportunidad de registrar la escucha en curso si ya cruzó el
    // umbral antes de que se cierre la app/controlador. Lee la posición en
    // vivo (ver `_onComplete`) para que esto sea una red de seguridad real.
    _trackListenProgress(_state.engine.copyWith(position: _engine.position));
    _disposed = true;
    _engineSub?.cancel();
    _completionSub?.cancel();
    _engineLogSub?.cancel();
    _logController.close();
    _engine.dispose();
    super.dispose();
  }
}
