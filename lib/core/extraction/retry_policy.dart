import 'models/extraction_result.dart';

/// Guard Anti-Bucle 403 (§2.3 Documento Maestro y Pitfalls #11 y #14).
/// Regla estricta: Máximo 1 reintento ante error 403 o de red.
/// Pausa inmediata tras el 2º fallo para evitar loops descontrolados.
class RetryPolicy {
  final Map<String, int> _attemptCount = {};

  /// Retorna true si se puede reintentar, false si se debe pausar.
  /// NUNCA permite más de 1 reintento ante 403 o error de red.
  bool canRetry(String videoId, ExtractionError error) {
    if (error == ExtractionError.notFound) return false; // no reintentar errores lógicos

    final attempts = _attemptCount[videoId] ?? 0;
    if (attempts >= 1) return false; // máximo 1 reintento para 403/red

    _attemptCount[videoId] = attempts + 1;
    return true;
  }

  void reset(String videoId) => _attemptCount.remove(videoId);

  int getAttemptCount(String videoId) => _attemptCount[videoId] ?? 0;
}
