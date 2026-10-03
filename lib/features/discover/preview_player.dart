// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../player/audio_engine/audio_engine_state.dart';

/// Reproductor de previews de 30 s de Deezer (Fase 8.F).
///
/// Es un motor de audio **propio**, aparte del reproductor principal: no toca
/// la cola, ni el historial de escucha, ni las estadísticas, ni los controles
/// del sistema operativo. Una preview no es una escucha.
///
/// Las URLs de preview de Deezer van firmadas y caducan (`hdnea=exp=...`): si
/// cargar una falla, se pide la URL fresca con [refreshUrl] y se reintenta
/// una sola vez.
class PreviewPlayer {
  PreviewPlayer({
    required AudioEngine Function() engineFactory,
    Future<String?> Function(int trackId)? refreshUrl,
  })  : _engineFactory = engineFactory,
        _refreshUrl = refreshUrl;

  final AudioEngine Function() _engineFactory;
  final Future<String?> Function(int trackId)? _refreshUrl;

  AudioEngine? _engine;
  final StreamController<AudioEngineState> _state = StreamController.broadcast();
  final StreamController<void> _completed = StreamController.broadcast();
  StreamSubscription<AudioEngineState>? _stateSub;
  StreamSubscription<void>? _completionSub;
  int? _currentTrackId;
  int? _retriedTrackId;
  int _generation = 0;
  bool _disposed = false;

  Stream<AudioEngineState> get stateStream => _state.stream;
  Stream<void> get completionStream => _completed.stream;
  int? get currentTrackId => _currentTrackId;

  AudioEngine _ensureEngine() {
    final existing = _engine;
    if (existing != null) return existing;
    final engine = _engineFactory();
    _stateSub = engine.stateStream.listen((s) {
      if (!_state.isClosed) _state.add(s);
      // En Windows (libmpv) una URL caducada no hace fallar `setUrl`: llega
      // como estado de error. Mismo reintento único con la URL fresca.
      if (s.processingState == AudioProcessingState.error) _retryWithFreshUrl();
    });
    _completionSub = engine.completionStream.listen((_) {
      if (!_completed.isClosed) _completed.add(null);
    });
    return _engine = engine;
  }

  /// Carga y reproduce la preview de [trackId]. Si llega otra llamada
  /// mientras esta carga, la vieja se descarta. Devuelve `false` si no se
  /// pudo reproducir ni con la URL refrescada.
  Future<bool> play(int trackId, String previewUrl) async {
    if (_disposed) return false;
    final generation = ++_generation;
    _currentTrackId = trackId;
    final engine = _ensureEngine();
    try {
      await engine.setUrl(previewUrl);
    } catch (_) {
      _retriedTrackId = trackId;
      final fresh = await _refreshUrl?.call(trackId);
      if (fresh == null || fresh.isEmpty || generation != _generation || _disposed) return false;
      try {
        await engine.setUrl(fresh);
      } catch (_) {
        return false;
      }
    }
    if (generation != _generation || _disposed) return false;
    await engine.play();
    return true;
  }

  Future<void> _retryWithFreshUrl() async {
    final trackId = _currentTrackId;
    if (trackId == null || _retriedTrackId == trackId || _disposed) return;
    _retriedTrackId = trackId;
    final generation = _generation;
    final fresh = await _refreshUrl?.call(trackId);
    final engine = _engine;
    if (fresh == null || fresh.isEmpty || engine == null || generation != _generation || _disposed) return;
    try {
      await engine.setUrl(fresh);
      if (generation == _generation && !_disposed) await engine.play();
    } catch (_) {}
  }

  Future<void> pause() async => _engine?.pause();

  Future<void> resume() async => _engine?.play();

  Future<void> stop() async {
    _generation++;
    _currentTrackId = null;
    await _engine?.stop();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _stateSub?.cancel();
    _completionSub?.cancel();
    _engine?.dispose();
    _engine = null;
    _state.close();
    _completed.close();
  }
}
