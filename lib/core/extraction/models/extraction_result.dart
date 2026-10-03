enum ExtractionError {
  notFound, // Error lógico — candidato a auto-skip
  rateLimited, // 403 persistente — PAUSAR, no hacer skip (Pitfall #11 y #14)
  networkError, // SocketException — 1 reintento, luego pausar
  cancelled, // Petición cancelada por superposición de nuevo track
  unknownError,
  // Fase 8.A: el motor de extracción está roto (no la canción). PAUSAR sin
  // marcar la pista como no disponible; el `EngineManager` ya está buscando
  // un motor que funcione y avisa cuando lo encuentra.
  engineBroken,
}

/// Resultado que viaja de vuelta al Main Isolate
sealed class ExtractionResult {
  final String requestId;
  const ExtractionResult(this.requestId);
}

class ExtractionSuccess extends ExtractionResult {
  final String streamUrl;
  final Map<String, String> headers; // headers obligatorios para el player (Pitfall #13)

  const ExtractionSuccess({
    required String requestId,
    required this.streamUrl,
    required this.headers,
  }) : super(requestId);
}

class ExtractionFailure extends ExtractionResult {
  final ExtractionError error;
  final String? message;

  /// Fase 8.A: YouTube contestó y aun así el motor no pudo usar la respuesta
  /// (vídeo encontrado sin streams en ningún cliente, excepción del parser,
  /// motor que no cargó). Lo marca solo el isolate; alimenta al
  /// `EngineHealthMonitor`. Un "no hay coincidencia" de catálogo nunca lo
  /// lleva.
  final bool suspectEngine;

  const ExtractionFailure({
    required String requestId,
    required this.error,
    this.message,
    this.suspectEngine = false,
  }) : super(requestId);
}
