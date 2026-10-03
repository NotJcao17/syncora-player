import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'engine/engine_manager.dart';
import 'extraction_service.dart';

bool get _isTestEnv {
  try {
    final name = WidgetsBinding.instance.runtimeType.toString();
    return name.contains('Test') || name.contains('Automated');
  } catch (_) {
    return true;
  }
}

final extractionServiceProvider = Provider<ExtractionService>((ref) {
  if (kIsWeb || _isTestEnv) {
    return ExtractionServiceMock();
  }
  final service = ExtractionServiceReal();
  // Fase 8: comprobación de motor nuevo 15 s después de arrancar y luego
  // periódica (máx. una cada 12 h). Solo descarga y guarda; no cambia el
  // motor en uso salvo que este falle.
  service.engineManager.scheduleBackgroundChecks();
  ref.onDispose(() {
    service.dispose();
  });
  return service;
});

/// Motor de extracción y su OTA (Fase 8). `null` en web y en tests, donde la
/// extracción es un doble sin motor real.
final engineManagerProvider = Provider<EngineManager?>((ref) {
  final service = ref.watch(extractionServiceProvider);
  return service is ExtractionServiceReal ? service.engineManager : null;
});
