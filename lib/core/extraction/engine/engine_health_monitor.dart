import '../models/extraction_result.dart';

/// Decide si el motor de extracción está roto (Fase 8.A, hallazgo H-8-4).
///
/// Antes, un motor roto se presentaba como "varias canciones seguidas no
/// están disponibles": el guard de cascada no distingue una canción que no
/// existe en YouTube de un motor que ya no sabe hablar con YouTube.
///
/// La señal fuerte es [ExtractionFailure.suspectEngine], que el isolate solo
/// marca cuando YouTube contestó y aun así el motor no pudo usar la respuesta
/// (vídeo encontrado pero `/player` sin streams en todos los clientes,
/// excepciones de código en el parser, búsquedas que fallan con YouTube
/// contestando). "Ningún candidato aceptable" o "sin resultados" son
/// problemas de catálogo y no cuentan.
///
/// Se exige que los fallos sean de pistas **distintas** y seguidos (sin un
/// solo éxito entre medio): reintentar la misma canción no debe bastar para
/// declarar el motor roto.
class EngineHealthMonitor {
  /// Fallos sospechosos en pistas distintas que declaran el motor roto.
  static const int failuresToBreak = 2;

  final List<String> _streak = [];
  bool _broken = false;

  bool get isBroken => _broken;

  /// Pistas que forman la racha actual (para que el reproductor pueda
  /// quitarles la marca de "no disponible": no era culpa de ellas).
  List<String> get streakKeys => List.unmodifiable(_streak);

  void recordSuccess() {
    _streak.clear();
    _broken = false;
  }

  /// Registra un fallo de la pista [key]. Devuelve `true` si con este fallo
  /// el motor queda (o sigue) declarado roto.
  bool recordFailure(String key, ExtractionFailure failure) {
    if (!failure.suspectEngine) return _broken;
    if (!_streak.contains(key)) _streak.add(key);
    if (_streak.length >= failuresToBreak) _broken = true;
    return _broken;
  }

  /// El motor no llegó a cargar: está roto sin necesidad de esperar fallos.
  void markLoadFailure() {
    _broken = true;
  }

  /// ¿El texto de error apunta a un fallo del propio código del motor (un
  /// bug, o un parser que ya no entiende la respuesta de YouTube) y no a la
  /// red o a una canción concreta?
  static bool isCodeError(String? message) {
    if (message == null) return false;
    final m = message.toLowerCase();
    const markers = [
      'is not a function',
      'is not defined',
      'referenceerror',
      'typeerror',
      'syntaxerror',
      'cannot read propert',
      'not an object',
      'innertube no encontrada',
      'error sintáctico en extractvideo',
      'el motor no cargó',
    ];
    return markers.any(m.contains);
  }
}
