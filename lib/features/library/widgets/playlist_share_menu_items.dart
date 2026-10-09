import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../auth/local_mode_provider.dart';
import '../playlist_permissions.dart';
import '../services/playlist_share_service.dart';

/// Opciones de compartir del menú de una playlist, iguales en Biblioteca y en
/// la pantalla de la playlist.
///
/// - Propia (con cuenta): "Compartir enlace" y, si ya es pública, "Dejar de
///   compartir".
/// - Guardada de otro usuario: "Copiar enlace", "Guardar una copia" (editable)
///   y "Quitar de tu biblioteca".
///
/// [menuContext] es el del menú (para cerrarlo); [context] el de la pantalla,
/// que sigue vivo después de cerrar el menú. [onUnfollowed] se llama tras
/// quitar una guardada (la pantalla de la playlist la usa para salir).
List<Widget> playlistShareMenuItems({
  required BuildContext menuContext,
  required BuildContext context,
  required WidgetRef ref,
  required Playlist playlist,
  VoidCallback? onUnfollowed,
}) {
  const style = TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600);
  final canEdit = ref.read(canEditProvider);
  final editColor = canEdit ? AppTheme.primary : AppTheme.muted;
  final offline = canEdit
      ? null
      : const Text('Sin conexión', style: TextStyle(color: AppTheme.muted, fontSize: 12));

  if (playlist.isFollowed) {
    return [
      ListTile(
        leading: Icon(AppIcons.broken(SolarIcons.LinkMinimalistic), color: AppTheme.primary),
        title: const Text('Copiar enlace', style: style),
        onTap: () {
          Navigator.pop(menuContext);
          sharePlaylistLink(context, ref, playlist);
        },
      ),
      ListTile(
        leading: Icon(AppIcons.broken(SolarIcons.Copy), color: editColor),
        title: Text('Guardar una copia', style: style.copyWith(color: editColor)),
        subtitle: offline ??
            const Text('Una versión tuya que sí puedes editar',
                style: TextStyle(color: AppTheme.secondary, fontSize: 12)),
        enabled: canEdit,
        onTap: () async {
          Navigator.pop(menuContext);
          final id = await copyFollowedPlaylist(context, ref, playlist);
          if (id != null && context.mounted) context.push('/playlist/$id');
        },
      ),
      ListTile(
        leading: Icon(AppIcons.broken(SolarIcons.MinusCircle), color: canEdit ? Colors.redAccent : AppTheme.muted),
        title: Text(
          'Quitar de tu biblioteca',
          style: style.copyWith(color: canEdit ? Colors.redAccent : AppTheme.muted),
        ),
        subtitle: offline,
        enabled: canEdit,
        onTap: () async {
          Navigator.pop(menuContext);
          final removed = await unfollowPlaylist(context, ref, playlist);
          if (removed) onUnfollowed?.call();
        },
      ),
    ];
  }

  if (ref.read(localModeProvider) || !canSharePlaylist(playlist)) return const [];

  return [
    ListTile(
      leading: Icon(AppIcons.broken(SolarIcons.Share), color: AppTheme.primary),
      title: const Text('Compartir enlace', style: style),
      subtitle: playlist.isPublic
          ? null
          : const Text('Se volverá pública', style: TextStyle(color: AppTheme.secondary, fontSize: 12)),
      onTap: () {
        Navigator.pop(menuContext);
        sharePlaylistLink(context, ref, playlist);
      },
    ),
    if (playlist.isPublic)
      ListTile(
        leading: Icon(AppIcons.broken(SolarIcons.Lock), color: editColor),
        title: Text('Dejar de compartir', style: style.copyWith(color: editColor)),
        subtitle: offline,
        enabled: canEdit,
        onTap: () {
          Navigator.pop(menuContext);
          stopSharingPlaylist(context, ref, playlist);
        },
      ),
  ];
}
