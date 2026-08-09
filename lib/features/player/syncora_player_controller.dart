import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/extraction/extraction_service.dart';
import '../../core/extraction/models/extraction_request.dart';
import '../../core/extraction/models/extraction_result.dart';
import '../../core/extraction/retry_policy.dart';
import '../../data/apis/deezer_api.dart';
import '../../data/local_db/daos/downloaded_track_dao.dart';
import '../../data/models/deezer/deezer_track.dart';

import 'audio_engine/audio_engine_state.dart';
import 'player_models.dart';
import 'session/player_session_storage.dart';

/// Snapshot inmutable del estado completo del reproductor (cola + reproducción).
///
/// Es el modelo que consumirá la UI en la Fase 3 (mini-player, fullscreen).
@immutable
class SyncoraPlayerState {
  final List<SyncoraTrack> queue;
  final int currentIndex;
  final AudioEngineState engine;
  final SyncoraRepeatMode repeatMode;
  final bool shuffle;
  final bool skipSilence;
  final String? activeContextId;

  bool get isShuffle => shuffle;
  bool get isSkipSilence => skipSilence;

  /// Pista activa (null si la cola está vacía).
  SyncoraTrack? get currentTrack =>
      (currentIndex >= 0 && currentIndex < queue.length)
          ? queue[currentIndex]
          : null;

  /// Último error de extracción relevante (403 / red / not found). Lo usa la UI
  /// para mostrar un mensaje (Pitfalls #11 y #14: pausa inmediata, no bucle).
  final ExtractionError? lastError;
  final String? lastErrorMessage;

  const SyncoraPlayerState({
    this.queue = const [],
    this.currentIndex = -1,
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
    List<SyncoraTrack>? queue,
    int? currentIndex,
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
      queue: queue ?? this.queue,
      currentIndex: currentIndex ?? this.currentIndex,
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
    bool Function()? isConnectedGetter,
  })  : _engine = engine, // ignore: prefer_initializing_formals
        _extractionService = extractionService, // ignore: prefer_initializing_formals
        _deezerApi = deezerApi, // ignore: prefer_initializing_formals
        _downloadedTrackDao = downloadedTrackDao,
        _isConnectedGetter = isConnectedGetter;

  final AudioEngine _engine;
  final ExtractionService _extractionService;
  final DeezerApi? _deezerApi;
  final DownloadedTrackDao? _downloadedTrackDao;
  final bool Function()? _isConnectedGetter;
  final RetryPolicy _retryPolicy = RetryPolicy();
  final PlayerSessionStorage _sessionStorage = PlayerSessionStorage();

  StreamSubscription<AudioEngineState>? _engineSub;
  StreamSubscription<void>? _completionSub;
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
    _restoreSession();
  }

  // ----------------------------------------------------------------------
  // API pública de control y gestión de cola
  // ----------------------------------------------------------------------

  /// Reemplaza la cola completa y (opcionalmente) arranca la reproducción
  /// desde [index].
  Future<void> setQueue(
    List<SyncoraTrack> tracks, {
    int startIndex = 0,
    bool autoplay = true,
    String? activeContextId,
  }) async {
    _restoredPositionSeconds = null;
    if (tracks.isEmpty) {
      await _microFadeOut();
      await _engine.stop();
      _state = SyncoraPlayerState.initial.copyWith(
        skipSilence: _state.skipSilence,
        repeatMode: _state.repeatMode,
        shuffle: _state.shuffle,
        clearContext: true,
      );
      _notify();
      _saveSession();
      return;
    }
    _state = _state.copyWith(
      queue: List.unmodifiable(tracks),
      currentIndex: startIndex,
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

  /// Reproduce la pista en [index] de la cola actual.
  Future<void> playIndex(int index) async {
    if (index < 0 || index >= _state.queue.length) return;
    _restoredPositionSeconds = null;
    _state = _state.copyWith(currentIndex: index, clearError: true);
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

  Future<void> skipToNext() async {
    if (_isTransitioning) return;
    _isTransitioning = true;
    try {
      final next = _computeNextIndex(autoAdvance: true);
      if (next == null) {
        // Fin de la cola sin repeat: intentar Autoplay con Deezer recommendations
        final handledAutoplay = await _tryAutoplay();
        if (!handledAutoplay) {
          await _engine.pause();
          _saveSession();
        }
        return;
      }
      _state = _state.copyWith(currentIndex: next, clearError: true);
      _notify();
      _saveSession();
      await playCurrent();
    } finally {
      _isTransitioning = false;
    }
  }

  /// Dispara Autoplay al llegar al final de la cola
  Future<bool> _tryAutoplay() async {
    if (_deezerApi == null || _state.queue.isEmpty) return false;

    final lastTrack = _state.queue.last;
    int? deezerTrackId = int.tryParse(lastTrack.id);

    // Si el ID no es un int válido, buscar la canción en Deezer para obtener su ID
    if (deezerTrackId == null) {
      try {
        final searchRes = await _deezerApi.search('${lastTrack.artist} ${lastTrack.title}');
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

    // Convertir a SyncoraTrack y filtrar canciones que ya están en la cola
    final existingIds = _state.queue.map((t) => t.id).toSet();
    final newTracks = recommendations
        .map((t) => t.toSyncoraTrack())
        .where((t) => !existingIds.contains(t.id))
        .toList();

    if (newTracks.isEmpty) return false;

    _log('[Autoplay] ${newTracks.length} pistas similares añadidas a la cola automáticamente.');
    final updatedQueue = List<SyncoraTrack>.from(_state.queue)..addAll(newTracks);
    final nextIndex = _state.currentIndex + 1;

    _state = _state.copyWith(
      queue: List.unmodifiable(updatedQueue),
      currentIndex: nextIndex,
      clearError: true,
    );
    _notify();
    _saveSession();
    await playCurrent();
    return true;
  }


  Future<void> skipToPrevious() async {
    if (_isTransitioning) return;
    _isTransitioning = true;
    try {
      // Si llevamos >3s reproduciéndola, reiniciar la pista actual.
      if (_state.engine.position.inSeconds > 3) {
        await _engine.seek(Duration.zero);
        return;
      }
      final prev = _computePrevIndex();
      if (prev == null) {
        await _engine.seek(Duration.zero);
        return;
      }
      _state = _state.copyWith(currentIndex: prev, clearError: true);
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

  /// Inserta la pista inmediatamente después de la pista actual [currentIndex].
  void playNext(SyncoraTrack track) {
    if (_state.queue.isEmpty || _state.currentIndex < 0) {
      _state = _state.copyWith(
        queue: List.unmodifiable([track]),
        currentIndex: 0,
      );
    } else {
      final updatedQueue = List<SyncoraTrack>.from(_state.queue);
      final insertIndex = _state.currentIndex + 1;
      updatedQueue.insert(insertIndex, track);
      _state = _state.copyWith(queue: List.unmodifiable(updatedQueue));
    }
    _notify();
    _saveSession();
  }

  /// Agrega una pista al final de la cola actual.
  void addToQueue(SyncoraTrack track) {
    final updatedQueue = List<SyncoraTrack>.from(_state.queue)..add(track);
    final newIndex = _state.currentIndex < 0 ? 0 : _state.currentIndex;
    _state = _state.copyWith(
      queue: List.unmodifiable(updatedQueue),
      currentIndex: newIndex,
    );
    _notify();
    _saveSession();
  }

  /// Reordena elementos en la cola asegurando la integridad de [currentIndex].
  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _state.queue.length) return;
    int targetIndex = newIndex;
    if (oldIndex < targetIndex) {
      targetIndex -= 1;
    }
    if (targetIndex < 0 || targetIndex >= _state.queue.length) return;
    if (oldIndex == targetIndex) return;

    final updated = List<SyncoraTrack>.from(_state.queue);
    final track = updated.removeAt(oldIndex);
    updated.insert(targetIndex, track);

    int newCurrentIndex = _state.currentIndex;
    if (_state.currentIndex == oldIndex) {
      newCurrentIndex = targetIndex;
    } else if (oldIndex < _state.currentIndex && targetIndex >= _state.currentIndex) {
      newCurrentIndex = _state.currentIndex - 1;
    } else if (oldIndex > _state.currentIndex && targetIndex <= _state.currentIndex) {
      newCurrentIndex = _state.currentIndex + 1;
    }

    _state = _state.copyWith(
      queue: List.unmodifiable(updated),
      currentIndex: newCurrentIndex,
    );
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

  /// Elimina una pista de la cola sin romper la reproducción en curso.
  Future<void> removeFromQueue(int index) async {
    if (index < 0 || index >= _state.queue.length) return;

    if (_state.queue.length == 1) {
      await _microFadeOut();
      await _engine.stop();
      _state = _state.copyWith(
        queue: const [],
        currentIndex: -1,
      );
      _notify();
      _saveSession();
      return;
    }

    final updated = List<SyncoraTrack>.from(_state.queue)..removeAt(index);
    final currentIdx = _state.currentIndex;

    if (index < currentIdx) {
      _state = _state.copyWith(
        queue: List.unmodifiable(updated),
        currentIndex: currentIdx - 1,
      );
      _notify();
      _saveSession();
    } else if (index > currentIdx) {
      _state = _state.copyWith(
        queue: List.unmodifiable(updated),
      );
      _notify();
      _saveSession();
    } else {
      // Se elimina la pista que está sonando actualmente
      int nextIdx = index;
      if (nextIdx >= updated.length) {
        nextIdx = updated.length - 1;
      }
      _state = _state.copyWith(
        queue: List.unmodifiable(updated),
        currentIndex: nextIdx,
        clearError: true,
      );
      _notify();
      _saveSession();
      await playCurrent();
    }
  }

  /// Limpia las canciones siguientes en la cola (cola próxima).
  void clearQueue() {
    if (_state.currentIndex < 0 || _state.queue.isEmpty) {
      _state = _state.copyWith(queue: const [], currentIndex: -1);
    } else {
      final remaining = _state.queue.sublist(0, _state.currentIndex + 1);
      _state = _state.copyWith(queue: List.unmodifiable(remaining));
    }
    _notify();
    _saveSession();
  }

  /// Alias de playIndex para saltar a un índice de la cola.
  Future<void> skipToQueueIndex(int index) => playIndex(index);

  void setShuffle(bool enabled) {
    _state = _state.copyWith(shuffle: enabled);
    _notify();
    _saveSession();
  }

  void toggleShuffle() {
    setShuffle(!_state.shuffle);
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
  // Lógica interna & Persistencia de Sesión
  // ----------------------------------------------------------------------

  int _lastSavedPositionSeconds = -1;

  void _saveSession() {
    _sessionStorage.saveSession(
      queue: _state.queue,
      currentIndex: _state.currentIndex,
      positionSeconds: _state.engine.position.inSeconds,
      repeatMode: _state.repeatMode,
      shuffle: _state.shuffle,
      activeContextId: _state.activeContextId,
    );
  }

  Future<void> _restoreSession() async {
    final session = await _sessionStorage.loadSession();
    if (session == null || session.queue.isEmpty) return;

    final restoredIndex = (session.currentIndex >= 0 && session.currentIndex < session.queue.length)
        ? session.currentIndex
        : 0;

    _restoredPositionSeconds = session.positionSeconds;
    final restoredDuration = (restoredIndex >= 0 && restoredIndex < session.queue.length)
        ? session.queue[restoredIndex].duration ?? Duration.zero
        : Duration.zero;

    _state = _state.copyWith(
      queue: List.unmodifiable(session.queue),
      currentIndex: restoredIndex,
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
    _log('[Session] Sesión restaurada: ${session.queue.length} pistas en cola, posición: ${session.positionSeconds}s (pausado)');
  }

  /// Salto silencioso automático cuando se intenta reproducir una pista no descargada estando offline.
  Future<void> _skipSilently() async {
    if (_isTransitioning) return;
    _isTransitioning = true;
    try {
      final next = _computeNextIndex(autoAdvance: true);
      if (next == null) {
        await _engine.pause();
        _saveSession();
        return;
      }
      _state = _state.copyWith(currentIndex: next, clearError: true);
      _notify();
      _saveSession();
      await playCurrent();
    } finally {
      _isTransitioning = false;
    }
  }

  /// Núcleo: resuelve la URL de la pista actual o carga el archivo local si está descargado.
  Future<void> playCurrent() async {
    final track = _state.currentTrack;
    if (track == null) return;

    // Detener inmediatamente cualquier audio previo con micro fade-out para evitar audio bleed/clics
    await _microFadeOut();
    await _engine.stop();

    final trackDeezerId = int.tryParse(track.id) ?? track.id.hashCode.abs();


    // 1. Verificar si existe descarga local (state == 2)
    if (_downloadedTrackDao != null && trackDeezerId > 0) {
      try {
        final downloaded = await _downloadedTrackDao.getByTrackId(trackDeezerId);
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
      await skipToNext();
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
    _state = _state.copyWith(engine: engineState);
    _notify();

    final currentPosSec = engineState.position.inSeconds;
    if (currentPosSec != _lastSavedPositionSeconds && (currentPosSec % 2 == 0 || !engineState.playing)) {
      _lastSavedPositionSeconds = currentPosSec;
      _saveSession();
    }
  }

  Future<void> _onComplete() async {
    if (_state.repeatMode == SyncoraRepeatMode.one) {
      await _engine.seek(Duration.zero);
      await _engine.play();
      return;
    }
    await skipToNext();
  }

  /// Calcula el siguiente índice respetando shuffle y repeat.
  int? _computeNextIndex({required bool autoAdvance}) {
    final queue = _state.queue;
    if (queue.isEmpty) return null;

    if (_state.shuffle) {
      if (queue.length == 1) {
        return _state.repeatMode == SyncoraRepeatMode.off ? null : 0;
      }
      final rnd = DateTime.now().microsecondsSinceEpoch % queue.length;
      return rnd == _state.currentIndex ? (rnd + 1) % queue.length : rnd;
    }

    final next = _state.currentIndex + 1;
    if (next < queue.length) return next;
    if (_state.repeatMode == SyncoraRepeatMode.all) return 0;
    return null;
  }

  int? _computePrevIndex() {
    final queue = _state.queue;
    if (queue.isEmpty) return null;
    final prev = _state.currentIndex - 1;
    if (prev >= 0) return prev;
    if (_state.repeatMode == SyncoraRepeatMode.all) return queue.length - 1;
    return null;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  void _log(String msg) {
    if (!_logController.isClosed) _logController.add(msg);
  }

  @override
  void dispose() {
    _disposed = true;
    _engineSub?.cancel();
    _completionSub?.cancel();
    _logController.close();
    _engine.dispose();
    super.dispose();
  }
}

