/// Ronda 9 (H-R9-2): cuando YouTube pide verificar que no es un bot, la
/// sesión que usa el motor (instancias de Innertube con su `visitorData` y las
/// cookies del puente de red) se renueva una vez y se reintenta antes de
/// pausar. Antes esa sesión duraba lo que el proceso: si YouTube la marcaba,
/// fallaban todas las canciones hasta reiniciar el teléfono.
///
/// Con enfriamiento: si la sesión recién renovada también lo pide, es la IP y
/// renovar en cada canción solo sumaría peticiones mientras siga bloqueada.
class YoutubeSessionRefresher {
  static const defaultCooldown = Duration(minutes: 1);

  YoutubeSessionRefresher({
    required this.reset,
    DateTime Function()? clock,
    this.cooldown = defaultCooldown,
  }) : _clock = clock ?? DateTime.now;

  final void Function() reset;
  final DateTime Function() _clock;
  final Duration cooldown;
  DateTime? _lastRefresh;

  /// `true` si renovó la sesión (vale la pena reintentar); `false` si ya se
  /// renovó hace menos de [cooldown] (toca pausar).
  bool refreshIfAllowed() {
    final now = _clock();
    final last = _lastRefresh;
    if (last != null && now.difference(last) < cooldown) return false;
    _lastRefresh = now;
    reset();
    return true;
  }
}
