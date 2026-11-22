import 'package:flutter/foundation.dart';

/// Ruta que pidió un widget de la pantalla de inicio y todavía no se abrió
/// (mismo patrón que `pendingSharedPlaylist`: el enlace puede llegar antes de
/// que exista el router).
final pendingWidgetRoute = ValueNotifier<String?>(null);

/// Ruta para un enlace `syncoraplayer://widget/...` de los widgets, o `null`.
///
/// - `widget/player` -> reproductor a pantalla completa.
/// - `widget/playlist/<id local>` -> esa playlist.
/// - `widget/album/<id de Deezer>` -> ese álbum.
String? widgetRouteFromUri(Uri uri) {
  if (uri.scheme != 'syncoraplayer' || uri.host != 'widget') return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return null;
  if (segments.first == 'player') return '/player';
  if (segments.length < 2) return null;
  final id = int.tryParse(segments[1]);
  if (id == null || id <= 0) return null;
  return switch (segments.first) {
    'playlist' => '/playlist/$id',
    'album' => '/album/$id',
    _ => null,
  };
}
