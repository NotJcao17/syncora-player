import 'dart:async';
import 'models/extraction_request.dart';
import 'models/extraction_result.dart';
import 'extraction_isolate.dart';

abstract class ExtractionService {
  Future<ExtractionResult> extractUrl(
    String videoId, {
    ExtractionPriority priority = ExtractionPriority.streaming,
  });

  void dispose();
}

class ExtractionServiceReal implements ExtractionService {
  final ExtractionIsolate _isolate = ExtractionIsolate();
  int _requestIdCounter = 0;

  Future<void> initialize() async {
    await _isolate.spawn();
  }

  @override
  Future<ExtractionResult> extractUrl(
    String videoId, {
    ExtractionPriority priority = ExtractionPriority.streaming,
  }) async {
    final requestId = 'req_${++_requestIdCounter}_${DateTime.now().millisecondsSinceEpoch}';
    final request = ExtractionRequest(
      videoId: videoId,
      requestId: requestId,
      priority: priority,
    );
    return _isolate.request(request);
  }

  @override
  void dispose() {
    _isolate.dispose();
  }
}

/// Mock para Web y Tests (Pitfall #6)
/// Devuelve siempre un .mp3 público para probar UI sin crashing por C++/Isolates nativos.
class ExtractionServiceMock implements ExtractionService {
  static const String _testUrl =
      'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3';

  @override
  Future<ExtractionResult> extractUrl(
    String videoId, {
    ExtractionPriority priority = ExtractionPriority.streaming,
  }) async {
    final requestId = 'mock_${DateTime.now().millisecondsSinceEpoch}';
    
    // Simular retardo de red
    await Future.delayed(const Duration(milliseconds: 300));

    if (videoId == 'invalid' || videoId == 'aaaaaaaaaaa') {
      return ExtractionFailure(
        requestId: requestId,
        error: ExtractionError.rateLimited,
        message: 'Mock error 403 simulado para ID inválido.',
      );
    }

    return ExtractionSuccess(
      requestId: requestId,
      streamUrl: _testUrl,
      headers: const {
        'User-Agent': 'Mozilla/5.0 SyncoraPlayerMock',
      },
    );
  }

  @override
  void dispose() {}
}
