enum ExtractionError {
  notFound, // Error lógico — candidato a auto-skip
  rateLimited, // 403 persistente — PAUSAR, no hacer skip (Pitfall #11 y #14)
  networkError, // SocketException — 1 reintento, luego pausar
  cancelled, // Petición cancelada por superposición de nuevo track
  unknownError,
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

  const ExtractionFailure({
    required String requestId,
    required this.error,
    this.message,
  }) : super(requestId);
}
