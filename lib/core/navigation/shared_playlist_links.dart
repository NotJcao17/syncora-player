import 'package:flutter/foundation.dart';

/// Playlist compartida que llegó por enlace y todavía no se abrió.
///
/// El enlace llega por `app_links` en `main.dart`, a veces antes de `runApp`
/// (la app arrancó en frío desde el enlace) y sin acceso al router. Se deja
/// aquí y `AppShell` lo abre en cuanto existe, así también espera a que el
/// usuario termine de iniciar sesión o elija el modo sin cuenta.
final pendingSharedPlaylist = ValueNotifier<String?>(null);

/// Id de playlist de un enlace compartido, o `null` si no es uno.
///
/// Acepta el esquema de la app (`syncoraplayer://playlist/<id>`, el que abre
/// la web) y la dirección de la web (`https://syncoraplayer.app/playlist/<id>`)
/// por si algún día se registran los App Links.
String? sharedPlaylistIdFromUri(Uri uri) {
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  String? id;
  if (uri.scheme == 'syncoraplayer' && uri.host == 'playlist' && segments.isNotEmpty) {
    id = segments.first;
  } else if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      (uri.host == 'syncoraplayer.app' || uri.host == 'www.syncoraplayer.app') &&
      segments.length >= 2 &&
      segments.first == 'playlist') {
    id = segments[1];
  }
  if (id == null) return null;
  final normalized = id.toLowerCase();
  final uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
  return uuid.hasMatch(normalized) ? normalized : null;
}
