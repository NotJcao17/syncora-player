import 'dart:async';
import 'models/extraction_request.dart';
import 'models/extraction_result.dart';
import 'extraction_isolate.dart';

abstract class ExtractionService {
  Stream<String> get onLogMessage;

  Future<ExtractionResult> extractUrl(
    String videoId, {
    ExtractionPriority priority = ExtractionPriority.streaming,
  });

  void resetEngine();

  void dispose();
}

class ExtractionServiceReal implements ExtractionService {
  final ExtractionIsolate _isolate = ExtractionIsolate();
  int _requestIdCounter = 0;

  @override
  Stream<String> get onLogMessage => _isolate.onLogMessage;

  Future<void> initialize() async {
    await _isolate.spawn();
  }

  @override
  Future<ExtractionResult> extractUrl(
    String videoId, {
    ExtractionPriority priority = ExtractionPriority.streaming,
  }) async {
    final requestId =
        'req_${++_requestIdCounter}_${DateTime.now().millisecondsSinceEpoch}';
    final request = ExtractionRequest(
      videoId: videoId,
      requestId: requestId,
      priority: priority,
    );
    return _isolate.request(request);
  }

  @override
  void resetEngine() {
    _isolate.resetEngine();
  }

  @override
  void dispose() {
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
    ExtractionPriority priority = ExtractionPriority.streaming,
  }) async {
    final requestId = 'mock_${DateTime.now().millisecondsSinceEpoch}';

    _mockLogController.add('[MockService] Extrayendo URL simulada...');
    await Future.delayed(const Duration(milliseconds: 300));

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
