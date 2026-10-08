import 'dart:async';
import 'engine/engine_manager.dart';
import 'models/extraction_request.dart';
import 'models/extraction_result.dart';
import 'extraction_isolate.dart';

abstract class ExtractionService {
  Stream<String> get onLogMessage;

  Future<ExtractionResult> extractUrl(
    String videoId, {
    String? trackTitle,
    String? trackArtist,
    int? durationSeconds,
    ExtractionPriority priority = ExtractionPriority.streaming,
    String? quality,
  });

  void resetEngine();

  void dispose();
}

class ExtractionServiceReal implements ExtractionService {
  ExtractionServiceReal() {
    _engine = EngineManager(isolate: _isolate);
  }

  final ExtractionIsolate _isolate = ExtractionIsolate();
  late final EngineManager _engine;
  int _requestIdCounter = 0;

  /// Estado del motor y OTA (Fase 8). Fuera de la interfaz a propósito: los
  /// dobles de test de [ExtractionService] no tienen motor.
  EngineManager get engineManager => _engine;

  @override
  Stream<String> get onLogMessage => _isolate.onLogMessage;

  Future<void> initialize() => _engine.ensureEngine();

  @override
  Future<ExtractionResult> extractUrl(
    String videoId, {
    String? trackTitle,
    String? trackArtist,
    int? durationSeconds,
    ExtractionPriority priority = ExtractionPriority.streaming,
    String? quality,
  }) async {
    final requestId =
        'req_${++_requestIdCounter}_${DateTime.now().millisecondsSinceEpoch}';

    if (videoId.startsWith('http://') || videoId.startsWith('https://')) {
      return ExtractionSuccess(
        requestId: requestId,
        streamUrl: videoId,
        headers: const {},
      );
    }

    final request = ExtractionRequest(
      videoId: videoId,
      requestId: requestId,
      priority: priority,
      trackTitle: trackTitle,
      trackArtist: trackArtist,
      durationSeconds: durationSeconds,
      quality: quality,
    );

    if (priority != ExtractionPriority.streaming) {
      await _engine.ensureEngine();
      final result = await _isolate.request(request);
      return _engine.process(request, result);
    }

    // Ronda 5 (H-R5-2): una sola extracción de streaming en el isolate a la
    // vez, y como mucho una esperando. El isolate procesa en orden, así que
    // al pulsar "siguiente" tres veces seguidas se esperaban las tres
    // extracciones; ahora la que espera se reemplaza por la más nueva y la
    // reemplazada vuelve como `cancelled` (el reproductor ya la ignora: es
    // de una pista que dejó atrás).
    if (_streamingBusy) {
      _streamingWaiter?.complete(false);
      final waiter = Completer<bool>();
      _streamingWaiter = waiter;
      final proceed = await waiter.future;
      if (!proceed) {
        return ExtractionFailure(
          requestId: requestId,
          error: ExtractionError.cancelled,
          message: 'Reemplazada por una petición más nueva.',
        );
      }
    }
    _streamingBusy = true;
    try {
      await _engine.ensureEngine();
      final result = await _isolate.request(request);
      return _engine.process(request, result);
    } finally {
      _streamingBusy = false;
      final next = _streamingWaiter;
      _streamingWaiter = null;
      next?.complete(true);
    }
  }

  bool _streamingBusy = false;
  Completer<bool>? _streamingWaiter;

  /// Búsqueda de canciones en YouTube Music (la usa la búsqueda por letra).
  /// Fuera de la interfaz, como [engineManager]: los dobles de test de
  /// [ExtractionService] no tienen motor; la UI la pide por
  /// `ytMusicSearchProvider`, que los tests sustituyen.
  Future<MusicSearchResponse> searchMusic(String query) async {
    await _engine.ensureEngine();
    final requestId = 'music_${++_requestIdCounter}_${DateTime.now().millisecondsSinceEpoch}';
    return _isolate.searchMusic(requestId, query);
  }

  @override
  void resetEngine() {
    _isolate.resetEngine();
  }

  @override
  void dispose() {
    _engine.dispose();
    _isolate.dispose();
  }
}

class ExtractionServiceMock implements ExtractionService {
  static const String _testUrl =
      'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3';

  final StreamController<String> _mockLogController =
      StreamController<String>.broadcast();

  @override
  Stream<String> get onLogMessage => _mockLogController.stream;

  @override
  Future<ExtractionResult> extractUrl(
    String videoId, {
    String? trackTitle,
    String? trackArtist,
    int? durationSeconds,
    ExtractionPriority priority = ExtractionPriority.streaming,
    String? quality,
  }) async {
    final requestId = 'mock_${DateTime.now().millisecondsSinceEpoch}';

    _mockLogController.add('[MockService] Extrayendo URL simulada...');

    if (videoId == 'invalid' || videoId == 'aaaaaaaaaaa') {
      _mockLogController
          .add('[MockService] Error simulado para videoId inválido');
      return ExtractionFailure(
        requestId: requestId,
        error: ExtractionError.rateLimited,
        message: 'Mock error 403 simulado para ID inválido.',
      );
    }

    _mockLogController.add('[MockService] Éxito simulado!');
    return ExtractionSuccess(
      requestId: requestId,
      streamUrl: _testUrl,
      headers: const {
        'User-Agent': 'Mozilla/5.0 SyncoraPlayerMock',
      },
    );
  }

  @override
  void resetEngine() {
    _mockLogController.add('[MockService] Motor reseteado');
  }

  @override
  void dispose() {
    _mockLogController.close();
  }
}
