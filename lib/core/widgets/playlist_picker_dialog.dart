import 'package:flutter/material.dart';

import '../../data/local_db/syncora_database.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import 'playlist_cover_widget.dart';

/// Selector compacto de playlist destino (miniatura + título, sin
/// descripción), compartido por "Agregar a playlist" de una canción y
/// "Agregar todas a otra playlist" (ronda 4: el segundo tenía su propio
/// diálogo con ícono genérico y descripción).
///
/// [containingIds] marca con el check de "ya está aquí" las playlists que
/// ya contienen la canción (ronda 4), el mismo ícono que en las listas.
///
/// Devuelve la playlist elegida o `null` si se cerró sin elegir.
Future<Playlist?> showPlaylistPickerDialog(
  BuildContext context, {
  required String title,
  required List<Playlist> playlists,
  Set<int> containingIds = const {},
}) {
  return showDialog<Playlist>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(title, style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 400),
        child: SizedBox(
          width: 340,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: playlists.length,
            itemBuilder: (c, i) {
              final pl = playlists[i];
              return ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: PlaylistCoverWidget(
                    playlistId: pl.id,
                    coverUrl: pl.coverUrl,
                    isLiked: pl.isLiked,
                    isGenerated: pl.isGenerated,
                    width: 36,
                    height: 36,
                    // Sin esto, `PlaylistCoverWidget` cae en su propio radio
                    // por defecto (16, pensado para portadas grandes) que en
                    // un thumbnail de 36px domina sobre el `ClipRRect(6)` de
                    // afuera y termina viéndose circular.
                    borderRadius: BorderRadius.circular(6),
                    memCacheWidth: 80,
                    memCacheHeight: 80,
                  ),
                ),
                // Ronda 4: letra más chica y hasta dos líneas; con una sola
                // línea casi todos los nombres se cortaban, más aún con el
                // check de "ya está aquí" a la derecha.
                title: Text(
                  pl.title,
                  style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 13.5),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                horizontalTitleGap: 12,
                trailing: containingIds.contains(pl.id)
                    ? Tooltip(
                        message: 'Ya está en esta playlist',
                        child: Icon(AppIcons.bold(SolarIcons.CheckCircle), color: AppTheme.accent, size: 18),
                      )
                    : null,
                onTap: () => Navigator.pop(ctx, pl),
              );
            },
          ),
        ),
      ),
    ),
  );
}
