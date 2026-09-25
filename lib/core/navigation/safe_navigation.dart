import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/player/player_models.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';

/// Navega a una pantalla del shell (artista, álbum...) desde cualquier sitio,
/// incluidas hojas modales y el reproductor a pantalla completa (ronda 4).
///
/// Bug que corrige: desde el menú de 3 puntos de una canción **dentro de la
/// cola** (una hoja modal abierta sobre el reproductor a pantalla completa,
/// que es una ruta raíz fuera del shell), "Ir al artista" hacía
/// `context.push('/artist/…')` con todo eso encima. GoRouter tenía que poner
/// la página del shell por encima de `/player` sin quitar la de abajo, la
/// misma página quedaba dos veces en el `Navigator` y la app caía con
/// `'!keyReservation.contains(key)': is not true`.
///
/// Aquí primero se cierra lo que haya encima (hojas y diálogos en el
/// navegador más cercano y en el raíz, y el reproductor a pantalla completa)
/// y la navegación se hace en el frame siguiente, ya con el árbol estable.
Future<void> navigateSafely(BuildContext context, String location) async {
  final router = GoRouter.of(context);
  final nearest = Navigator.of(context);
  final root = Navigator.of(context, rootNavigator: true);

  bool isPage(Route<dynamic> route) => route.settings is Page;
  nearest.popUntil(isPage);
  if (!identical(nearest, root)) root.popUntil(isPage);

  if (router.routerDelegate.currentConfiguration.uri.path == '/player' && router.canPop()) {
    router.pop();
  }

  await WidgetsBinding.instance.endOfFrame;
  router.push(location);
}

/// Artistas navegables de [track]: los colaboradores con id real o, si no
/// hay lista, el artista principal.
List<SyncoraArtistRef> navigableArtists(SyncoraTrack track) {
  final withId = <SyncoraArtistRef>[];
  final seen = <int>{};
  for (final a in track.artists) {
    if (a.id != 0 && seen.add(a.id)) withId.add(a);
  }
  if (withId.isNotEmpty) return withId;
  final mainId = track.artistId ?? 0;
  if (mainId == 0) return const [];
  return [SyncoraArtistRef(id: mainId, name: track.artist)];
}

/// "Ir al artista": con varios artistas deja elegir (hoja en móvil, diálogo
/// en escritorio) y después navega con [navigateSafely].
Future<void> goToTrackArtist(BuildContext context, SyncoraTrack track) async {
  final artists = navigableArtists(track);
  if (artists.isEmpty) return;
  var target = artists.first;
  if (artists.length > 1) {
    final picked = await _pickArtist(context, artists);
    if (picked == null) return;
    target = picked;
  }
  if (!context.mounted) return;
  await navigateSafely(context, '/artist/${target.id}');
}

Future<SyncoraArtistRef?> _pickArtist(BuildContext context, List<SyncoraArtistRef> artists) {
  Widget options(BuildContext ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final a in artists)
            ListTile(
              leading: Icon(AppIcons.broken(SolarIcons.User), color: AppTheme.secondary),
              title: Text(a.name, style: const TextStyle(color: AppTheme.primary)),
              onTap: () => Navigator.pop(ctx, a),
            ),
        ],
      );

  final isDesktop = MediaQuery.sizeOf(context).width >= 768;
  if (isDesktop) {
    return showDialog<SyncoraArtistRef>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Ir al artista', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
        content: SizedBox(width: 320, child: options(ctx)),
      ),
    );
  }
  return showModalBottomSheet<SyncoraArtistRef>(
    context: context,
    backgroundColor: AppTheme.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Ir al artista',
                  style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ),
          options(ctx),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
