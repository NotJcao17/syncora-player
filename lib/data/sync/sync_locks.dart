/// Playlists que el sync no debe tocar por ahora (ronda 4).
///
/// La importación en segundo plano sube cada bloque a la nube y luego lo
/// inserta en local. Si mientras tanto el sync de la playlist (se dispara al
/// abrirla, justo después de empezar a importar) insertaba las mismas pistas
/// por su cuenta, las dos escrituras se pisaban: órdenes repetidos y alguna
/// canción de la mitad colada al principio. Mientras una importación está
/// activa, el sync se salta esa playlist; al terminar vuelve a la normalidad.
class SyncLocks {
  SyncLocks._();

  static final Set<String> _lockedRemoteIds = {};

  static void lock(String remoteId) => _lockedRemoteIds.add(remoteId);
  static void unlock(String remoteId) => _lockedRemoteIds.remove(remoteId);
  static bool isLocked(String? remoteId) => remoteId != null && _lockedRemoteIds.contains(remoteId);
}
