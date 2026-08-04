import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/extraction/extraction_service.dart';
import '../../core/extraction/models/extraction_request.dart';
import '../../core/extraction/models/extraction_result.dart';
import '../../core/extraction/retry_policy.dart';
import '../../core/extraction/yt_matcher_service.dart';
import 'audio_engine/audio_engine_state.dart';
import 'player_models.dart';

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
///
/// Los controles del SO (audio_service / smtc_windows) se acoplan en el Paso 3
/// y delegan aquí.
class SyncoraPlayerController extends ChangeNotifier {
  SyncoraPlayerController({
    required this._engine,
    required this._extractionService,
  });

  final AudioEngine _engine;
  final ExtractionService _extractionService;
  final RetryPolicy _retryPolicy = RetryPolicy();
  final YtMatcherService _ytMatcher = YtMatcherService();

  StreamSubscription<AudioEngineState>? _engineSub;
  StreamSubscription<void>? _completionSub;
  bool _disposed = false;

  SyncoraPlayerState _state = SyncoraPlayerState.initial;

  SyncoraPlayerState get state => _state;

  // Flujo de logs para depuración.
  final StreamController<String> _logController =
      StreamController<String>.broadcast();
  Stream<String> get onLogMessage => _logController.stream;

  // Flag anti-reentrada: evita que skipToNext/skipToPrevious disparen cadenas
  // recursivas mientras una extracción está en curso.
  bool _isTransitioning = false;

  /// Inicializa suscripciones a los streams del motor.
  void init() {
    _engineSub = _engine.stateStream.listen(_onEngineState);
    _completionSub = _engine.completionStream.listen((_) => _onComplete());
  }

  // ----------------------------------------------------------------------
  // API pública de control
  // ----------------------------------------------------------------------

  /// Reemplaza la cola completa y (opcionalmente) arranca la reproducción
  /// desde [index].
  Future<void> setQueue(
    List<SyncoraTrack> tracks, {
    int startIndex = 0,
    bool autoplay = true,
  }) async {
    if (tracks.isEmpty) {
      await _engine.stop();
      _state = SyncoraPlayerState.initial.copyWith(
        skipSilence: _state.skipSilence,
        repeatMode: _state.repeatMode,
        shuffle: _state.shuffle,
      );
      _notify();
      return;
    }
    _state = _state.copyWith(
      queue: List.unmodifiable(tracks),
      currentIndex: startIndex,
      clearError: true,
    );
    _notify();
    if (autoplay) {
      await playCurrent();
    }
  }

  /// Reproduce la pista en [index] de la cola actual.
  Future<void> playIndex(int index) async {
    if (index < 0 || index >= _state.queue.length) return;
    _state = _state.copyWith(currentIndex: index, clearError: true);
    _notify();
    await playCurrent();
  }

  Future<void> play() async {
    await _engine.play();
  }

  Future<void> pause() async {
    await _engine.pause();
  }

  Future<void> seek(Duration position) async {
    await _engine.seek(position);
  }

  Future<void> stop() async {
    await _engine.stop();
  }

  Future<void> skipToNext() async {
    if (_isTransitioning) return;
    _isTransitioning = true;
    try {
      final next = _computeNextIndex(autoAdvance: true);
      if (next == null) {
        // Fin de la cola sin repeat: pausar.
        await _engine.pause();
        return;
      }
      _state = _state.copyWith(currentIndex: next, clearError: true);
      _notify();
      await playCurrent();
    } finally {
      _isTransitioning = false;
    }
  }

  Future<void> skipToPrevious() async {
    if (_isTransitioning) return;
    _isTransitioning = true;
    try {
      // Si llevamos >3s reproduciéndola, reiniciar la pista actual (comportamiento
      // estándar de reproductores).
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
      await playCurrent();
    } finally {
      _isTransitioning = false;
    }
  }

  void setRepeatMode(SyncoraRepeatMode mode) {
    _state = _state.copyWith(repeatMode: mode);
    _notify();
  }

  void cycleRepeatMode() {
    final next = switch (_state.repeatMode) {
      SyncoraRepeatMode.off => SyncoraRepeatMode.all,
      SyncoraRepeatMode.all => SyncoraRepeatMode.one,
      SyncoraRepeatMode.one => SyncoraRepeatMode.off,
    };
    setRepeatMode(next);
  }

  /// Agrega una pista a la cola actual.
  void addToQueue(SyncoraTrack track) {
    final updatedQueue = List<SyncoraTrack>.from(_state.queue)..add(track);
    final newIndex = _state.currentIndex < 0 ? 0 : _state.currentIndex;
    _state = _state.copyWith(
      queue: List.unmodifiable(updatedQueue),
      currentIndex: newIndex,
    );
    _notify();
  }

  /// Alias de playIndex para saltar a un índice de la cola.
  Future<void> skipToQueueIndex(int index) => playIndex(index);

  void setShuffle(bool enabled) {
    _state = _state.copyWith(shuffle: enabled);
    _notify();
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
  // Lógica interna
  // ----------------------------------------------------------------------

  /// Núcleo: resuelve la URL de la pista actual vía [ExtractionService] y la
  /// carga en el motor. Aplica el guard anti-bucle 403 (Pitfalls #11/#14):
  /// errores lógicos (notFound) hacen auto-skip; errores 403/red respetan
  /// máximo 1 reintento y luego pausan inmediatamente.
  Future<void> playCurrent() async {
    final track = _state.currentTrack;
    if (track == null) return;

    String targetId = (track.youtubeVideoId != null && track.youtubeVideoId!.isNotEmpty)
        ? track.youtubeVideoId!
        : track.id;

    if (!RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(targetId)) {
      _log('[Play] Buscando coincidencia de YouTube para "${track.artist} - ${track.title}"...');
      final resolvedId = await _ytMatcher.findYoutubeVideoId(track);
      if (resolvedId != null && resolvedId.isNotEmpty) {
        targetId = resolvedId;
      }
    }

    _log('[Play] Resolviendo extracción de YouTube para ${track.title} ($targetId)');
    final result = await _extractionService.extractUrl(
      targetId,
      priority: ExtractionPriority.streaming,
    );

    switch (result) {
      case ExtractionSuccess(:final streamUrl, :final headers):
        _log('[Play] URL resuelta, cargando en el motor...');
        _retryPolicy.reset(track.id); // extracción exitosa: resetear contador
        try {
          await _engine.setUrl(streamUrl, headers: headers);
          await _engine.play();
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

    // Error lógico (metadata ausente, video privado) → auto-skip inmediato.
    // Pitfall #14: el auto-skip solo es ciego para errores lógicos.
    if (error == ExtractionError.notFound || error == ExtractionError.unknownError) {
      _state = _state.copyWith(
        lastError: error,
        lastErrorMessage: message,
      );
      _notify();
      // Auto-skip a la siguiente pista disponible (sin bucle: si toda la cola
      // falla por notFound, se llega al final y se pausa).
      await skipToNext();
      return;
    }

    // Error de red / 403 → Guard: máximo 1 reintento (Pitfalls #11/#14).
    final canRetry = _retryPolicy.canRetry(track.id, error);
    if (canRetry) {
      _log('[Play] Reintentando (intento ${_retryPolicy.getAttemptCount(track.id)})...');
      await playCurrent();
      return;
    }

    // Agotado el reintento → PAUSA INMEDIATA. NUNCA auto-skip ciego ante 403/red
    // (evitaría vaciar la cola en 2s y aseguraría un baneo de IP).
    _log('[Play] Pausa inmediata por $error persistente (guard 403).');
    await _engine.pause();
    _state = _state.copyWith(
      lastError: error,
      lastErrorMessage: message ?? 'Reproducción pausada por error persistente.',
    );
    _notify();
  }

  void _onEngineState(AudioEngineState engineState) {
    _state = _state.copyWith(engine: engineState);
    _notify();
  }

  Future<void> _onComplete() async {
    // Repeat one → volver a reproducir la misma pista.
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
      // Shuffle simple: índice aleatorio distinto al actual (si la cola lo
      // permite). El Smart Shuffle completo es Fase 7.
      if (queue.length == 1) {
        return _state.repeatMode == SyncoraRepeatMode.off ? null : 0;
      }
      final rnd = DateTime.now().microsecondsSinceEpoch % queue.length;
      return rnd == _state.currentIndex ? (rnd + 1) % queue.length : rnd;
    }

    final next = _state.currentIndex + 1;
    if (next < queue.length) return next;
    // Fin de cola.
    if (_state.repeatMode == SyncoraRepeatMode.all) return 0;
    return null; // sin repeat → pausar
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
