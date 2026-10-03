import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/extraction/engine/engine_health_monitor.dart';
import 'package:syncora_player/core/extraction/models/extraction_result.dart';

ExtractionFailure _fail({bool suspect = true, String? message}) => ExtractionFailure(
      requestId: 'r',
      error: ExtractionError.notFound,
      message: message,
      suspectEngine: suspect,
    );

void main() {
  test('dos pistas distintas con fallo sospechoso declaran el motor roto', () {
    final m = EngineHealthMonitor();
    expect(m.recordFailure('a', _fail()), isFalse);
    expect(m.recordFailure('b', _fail()), isTrue);
    expect(m.streakKeys, ['a', 'b']);
  });

  test('reintentar la misma pista no basta', () {
    final m = EngineHealthMonitor();
    m.recordFailure('a', _fail());
    expect(m.recordFailure('a', _fail()), isFalse);
  });

  test('"no hay coincidencia" de catálogo no cuenta', () {
    final m = EngineHealthMonitor();
    for (final k in ['a', 'b', 'c', 'd']) {
      expect(m.recordFailure(k, _fail(suspect: false)), isFalse);
    }
  });

  test('un éxito entre medio rompe la racha', () {
    final m = EngineHealthMonitor();
    m.recordFailure('a', _fail());
    m.recordSuccess();
    expect(m.recordFailure('b', _fail()), isFalse);
  });

  test('un motor que no cargó está roto de inmediato', () {
    final m = EngineHealthMonitor()..markLoadFailure();
    expect(m.isBroken, isTrue);
  });

  test('isCodeError distingue bugs del motor de errores de contenido', () {
    expect(EngineHealthMonitor.isCodeError("TypeError: cannot read property 'x' of undefined"), isTrue);
    expect(EngineHealthMonitor.isCodeError('ReferenceError: extractVideo is not defined'), isTrue);
    expect(EngineHealthMonitor.isCodeError('Streaming data not available'), isFalse);
    expect(EngineHealthMonitor.isCodeError(null), isFalse);
  });
}
