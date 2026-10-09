import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/share_link_builder.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../../data/sync/sync_service.dart';
import '../../auth/local_mode_provider.dart';
import '../../catalog/save_collection_service.dart';
import '../../player/player_models.dart';
import '../../../data/local_db/playlist_track_mapper.dart';
import '../playlist_permissions.dart';

/// Compartir playlists por enlace y guardar las que comparten otros.
///
/// Compartir es hacerla pública: el enlace (`syncoraplayer.app/playlist/<id>`)
/// solo funciona si el RLS deja leer la fila, así que copiar el enlace de una
/// privada pide confirmación y la publica. "Dejar de compartir" la vuelve
/// privada: el enlace deja de funcionar y quien la guardó la pierde en su
/// siguiente sync.

/// `sourceRef` de la copia editable de una playlist compartida.
String sharedPlaylistSourceRef(String remoteId) => 'shared_playlist:$remoteId';

/// Copia el enlace de [playlist]; si todavía es privada, pregunta y la publica.
Future<void> sharePlaylistLink(BuildContext context, WidgetRef ref, Playlist playlist) async {
  final remoteId = playlist.remoteId;

  // Una guardada ya es pública: su enlace se puede pasar tal cual.
  if (playlist.isFollowed) {
    if (remoteId == null) return;
    await Clipboard.setData(ClipboardData(text: ShareLinkBuilder.playlist(remoteId)));
    if (context.mounted) AppToast.show(context, message: 'Enlace copiado');
    return;
  }

  if (!canSharePlaylist(playlist)) return;
  if (ref.read(localModeProvider)) {
    AppToast.show(context, message: 'Para compartir playlists necesitas una cuenta.');
    return;
  }
  if (remoteId == null) {
    // Se creó sin red y todavía no sube: el sync la sube y el enlace funcionará.
    ref.read(syncServiceProvider).syncLibrary(force: true);
    AppToast.show(context, message: 'Esta playlist todavía no está en la nube. Inténtalo en un momento.');
    return;
  }

  if (!playlist.isPublic) {
    if (!ref.read(canEditProvider)) {
      AppToast.show(context, message: 'Sin conexión: no se puede compartir ahora.');
      return;
    }
    final confirmed = await _confirm(
      context,
      title: 'Compartir playlist',
      body: 'Para compartirla, la playlist se vuelve pública: cualquiera con el enlace podrá ver su '
          'nombre, descripción, portada y canciones, y otros usuarios de Syncora podrán guardarla en '
          'su biblioteca. Tu nombre y tu correo no se muestran.\n\n'
          'Puedes dejar de compartirla cuando quieras desde su menú.',
      action: 'Compartir',
    );
    if (confirmed != true || !context.mounted) return;

    // Primero la nube (Pitfall #28): si no acepta el cambio, el enlace no
    // funcionaría y el siguiente sync revertiría lo local.
    try {
      await ref.read(supabasePlaylistRepositoryProvider).updatePlaylist(remoteId, isPublic: true);
    } catch (_) {
      if (context.mounted) AppToast.show(context, message: 'No se pudo compartir. Revisa tu conexión.');
      return;
    }
    final dao = ref.read(playlistDaoProvider);
    final fresh = await dao.getPlaylistById(playlist.id) ?? playlist;
    await dao.updatePlaylist(fresh.copyWith(isPublic: true));
  }

  await Clipboard.setData(ClipboardData(text: ShareLinkBuilder.playlist(remoteId)));
  if (context.mounted) AppToast.show(context, message: 'Enlace copiado');
}

/// Vuelve privada una playlist compartida.
Future<void> stopSharingPlaylist(BuildContext context, WidgetRef ref, Playlist playlist) async {
  final remoteId = playlist.remoteId;
  if (remoteId == null || !playlist.isPublic || !canSharePlaylist(playlist)) return;
  if (!ref.read(canEditProvider)) {
    AppToast.show(context, message: 'Sin conexión: no se puede cambiar ahora.');
    return;
  }
  final confirmed = await _confirm(
    context,
    title: 'Dejar de compartir',
    body: 'El enlace dejará de funcionar y quienes la guardaron ya no podrán verla.',
    action: 'Dejar de compartir',
  );
  if (confirmed != true || !context.mounted) return;

  try {
    await ref.read(supabasePlaylistRepositoryProvider).updatePlaylist(remoteId, isPublic: false);
  } catch (_) {
    if (context.mounted) AppToast.show(context, message: 'No se pudo guardar el cambio. Revisa tu conexión.');
    return;
  }
  final dao = ref.read(playlistDaoProvider);
  final fresh = await dao.getPlaylistById(playlist.id) ?? playlist;
  await dao.updatePlaylist(fresh.copyWith(isPublic: false));
  if (context.mounted) AppToast.show(context, message: 'La playlist ya no se comparte');
}

/// Guarda en la biblioteca la playlist compartida [remoteId], de solo lectura.
///
/// Devuelve el id local, o `null` si la playlist ya no está disponible.
/// Lanza si no hay red o si la nube rechaza el guardado.
Future<int?> followSharedPlaylist(WidgetRef ref, String remoteId) async {
  await ref.read(supabasePlaylistRepositoryProvider).followPlaylist(remoteId);
  return ref.read(syncServiceProvider).pullFollowedPlaylist(remoteId);
}

/// Quita de la biblioteca una playlist guardada de otro usuario.
Future<bool> unfollowPlaylist(BuildContext context, WidgetRef ref, Playlist playlist) async {
  final remoteId = playlist.remoteId;
  if (!playlist.isFollowed || remoteId == null) return false;
  if (!ref.read(canEditProvider)) {
    AppToast.show(context, message: 'Sin conexión: no se puede quitar ahora.');
    return false;
  }
  try {
    await ref.read(supabasePlaylistRepositoryProvider).unfollowPlaylist(remoteId);
  } catch (_) {
    if (context.mounted) AppToast.show(context, message: 'No se pudo quitar. Revisa tu conexión.');
    return false;
  }
  await ref.read(playlistDaoProvider).deletePlaylist(playlist.id);
  if (context.mounted) AppToast.show(context, message: 'Quitada de tu biblioteca');
  return true;
}

/// Hace una copia editable de una playlist guardada. Devuelve su id local.
Future<int?> copyFollowedPlaylist(BuildContext context, WidgetRef ref, Playlist playlist) async {
  final remoteId = playlist.remoteId;
  if (!playlist.isFollowed || remoteId == null) return null;
  if (!ref.read(canEditProvider)) {
    AppToast.show(context, message: 'Sin conexión: no se puede guardar ahora.');
    return null;
  }
  final dao = ref.read(playlistDaoProvider);
  final tracks = (await dao.getTracksOrdered(playlist.id)).map(playlistTrackToSyncora).toList();
  if (!context.mounted) return null;
  return copySharedTracks(
    context,
    ref,
    remoteId: remoteId,
    title: playlist.title,
    description: playlist.description,
    tracks: tracks,
  );
}

/// Copia editable a partir de las pistas de una playlist compartida.
Future<int?> copySharedTracks(
  BuildContext context,
  WidgetRef ref, {
  required String remoteId,
  required String title,
  String? description,
  required List<SyncoraTrack> tracks,
}) async {
  try {
    final id = await ensureCollectionSaved(
      sourceRef: sharedPlaylistSourceRef(remoteId),
      title: title,
      description: description,
      tracks: tracks,
      dao: ref.read(playlistDaoProvider),
      supabaseRepo: ref.read(supabasePlaylistRepositoryProvider),
    );
    if (context.mounted) AppToast.show(context, message: 'Copia guardada en tu biblioteca');
    return id;
  } catch (_) {
    if (context.mounted) AppToast.show(context, message: 'No se pudo guardar la copia');
    return null;
  }
}

Future<bool?> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dCtx) => AlertDialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(title, style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
      content: Text(body, style: const TextStyle(color: AppTheme.secondary, height: 1.4)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Cancelar')),
        ElevatedButton(onPressed: () => Navigator.pop(dCtx, true), child: Text(action)),
      ],
    ),
  );
}
