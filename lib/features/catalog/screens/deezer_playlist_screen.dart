import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/error_state.dart';
import '../../../data/apis/deezer_catalog_providers.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../auth/local_mode_provider.dart';
import '../../player/player_models.dart';
import '../save_collection_service.dart';
import '../widgets/collection_scaffold.dart';
import '../widgets/save_collection_button.dart';

/// Playlist de Deezer (`/deezer-playlist/:id`): editoriales de Inicio, tops por
/// país y playlists de la pantalla de género.
///
/// Antes de esta pantalla, tocar una playlist editorial en Inicio solo mostraba
/// un `AppToast` con su nombre — no había forma de abrirla.
class DeezerPlaylistScreen extends ConsumerWidget {
  final String playlistId;

  const DeezerPlaylistScreen({super.key, required this.playlistId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = int.tryParse(playlistId) ?? 0;
    if (id <= 0) {
      return const Scaffold(
        backgroundColor: AppTheme.background,
        body: ErrorStateWidget(message: 'Playlist no válida'),
      );
    }

    final playlistAsync = ref.watch(deezerPlaylistProvider(id));

    return playlistAsync.when(
      loading: () => const Scaffold(
        backgroundColor: AppTheme.background,
        body: Center(child: CircularProgressIndicator(color: AppTheme.primary)),
      ),
      error: (e, _) => Scaffold(
        backgroundColor: AppTheme.background,
        body: ErrorStateWidget(
          message: 'No pudimos cargar esta playlist',
          onRetry: () => ref.invalidate(deezerPlaylistProvider(id)),
        ),
      ),
      data: (playlist) {
        final tracks = playlist.tracks.map((t) => t.toSyncoraTrack()).toList();
        final sourceRef = 'deezer_playlist:$id';
        const description = 'Copia de una playlist de Deezer';

        return CollectionScaffold(
          label: 'Playlist',
          title: playlist.title,
          subtitle: '${playlist.userName} • ${tracks.length} canciones',
          coverUrl: playlist.pictureUrl,
          tracks: tracks,
          contextId: 'deezer_playlist_$id',
          onRefresh: () async => ref.invalidate(deezerPlaylistProvider(id)),
          emptyMessage: 'Deezer no devolvió canciones reproducibles para esta playlist.',
          onBeforeDownload: () => _saveBeforeDownload(
            context,
            ref,
            sourceRef: sourceRef,
            title: playlist.title,
            description: description,
            tracks: tracks,
          ),
          actions: [
            SaveCollectionButton(
              sourceRef: sourceRef,
              title: playlist.title,
              description: description,
              tracks: tracks,
            ),
          ],
        );
      },
    );
  }
}

/// Guarda la copia antes de dejar descargar.
///
/// Descargar algo que no está en la biblioteca dejaba pistas descargadas sin
/// ninguna colección a la que pertenecieran. Se hace en el mismo gesto, sin
/// obligar al usuario a guardar primero a mano.
Future<bool> _saveBeforeDownload(
  BuildContext context,
  WidgetRef ref, {
  required String sourceRef,
  required String title,
  String? description,
  required List<SyncoraTrack> tracks,
}) async {
  final dao = ref.read(playlistDaoProvider);
  if (await dao.getPlaylistBySourceRef(sourceRef) != null) return true;

  if (!ref.read(canEditProvider)) {
    if (context.mounted) {
      AppToast.show(context, message: 'Sin conexión: guarda la playlist cuando vuelvas a tener red');
    }
    return false;
  }

  try {
    await ensureCollectionSaved(
      sourceRef: sourceRef,
      title: title,
      description: description,
      tracks: tracks,
      dao: dao,
      supabaseRepo: ref.read(supabasePlaylistRepositoryProvider),
    );
    ref.invalidate(savedCollectionProvider(sourceRef));
    if (context.mounted) {
      AppToast.show(context, message: 'Guardada en tu biblioteca para poder descargarla');
    }
    return true;
  } catch (_) {
    if (context.mounted) {
      AppToast.show(context, message: 'No se pudo guardar la playlist');
    }
    return false;
  }
}
