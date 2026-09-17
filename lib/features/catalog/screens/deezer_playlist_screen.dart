import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icons.dart';
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

/// Playlist de Deezer (`/deezer-playlist/:id`): editoriales de Inicio, tops por
/// país y playlists de la pantalla de género.
///
/// Antes de esta pantalla, tocar una playlist editorial en Inicio solo mostraba
/// un `AppToast` con su nombre — no había forma de abrirla. Era el destino
/// muerto más visible de la app.
class DeezerPlaylistScreen extends ConsumerStatefulWidget {
  final String playlistId;

  const DeezerPlaylistScreen({super.key, required this.playlistId});

  @override
  ConsumerState<DeezerPlaylistScreen> createState() => _DeezerPlaylistScreenState();
}

class _DeezerPlaylistScreenState extends ConsumerState<DeezerPlaylistScreen> {
  bool _isSaving = false;

  @override
  Widget build(BuildContext context) {
    final id = int.tryParse(widget.playlistId) ?? 0;
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

        return CollectionScaffold(
          label: 'Playlist',
          title: playlist.title,
          subtitle: '${playlist.userName} • ${tracks.length} canciones',
          coverUrl: playlist.pictureUrl,
          tracks: tracks,
          contextId: 'deezer_playlist_$id',
          onRefresh: () async => ref.invalidate(deezerPlaylistProvider(id)),
          emptyMessage: 'Deezer no devolvió canciones reproducibles para esta playlist.',
          actions: [
            _SaveCopyButton(
              isSaving: _isSaving,
              onPressed: tracks.isEmpty ? null : () => _saveCopy(playlist.title, tracks),
            ),
          ],
        );
      },
    );
  }

  Future<void> _saveCopy(String title, List<SyncoraTrack> tracks) async {
    // Online-First (Pitfall #28): sin conexión y con cuenta, la playlist solo
    // llegaría a Drift y el siguiente sync la podaría.
    if (!ref.read(canEditProvider)) {
      AppToast.show(context, message: 'Sin conexión: no se puede guardar ahora');
      return;
    }
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      await saveTracksAsPlaylist(
        title: title,
        description: 'Copia de una playlist de Deezer',
        tracks: tracks,
        dao: ref.read(playlistDaoProvider),
        supabaseRepo: ref.read(supabasePlaylistRepositoryProvider),
      );
      if (!mounted) return;
      AppToast.show(context, message: 'Guardada en tu biblioteca');
    } catch (_) {
      if (!mounted) return;
      AppToast.show(context, message: 'No se pudo guardar la playlist');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}

class _SaveCopyButton extends StatelessWidget {
  final bool isSaving;
  final VoidCallback? onPressed;

  const _SaveCopyButton({required this.isSaving, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: isSaving
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.secondary),
            )
          : Icon(
              AppIcons.broken(SolarIcons.AddCircle),
              color: onPressed == null ? AppTheme.muted : AppTheme.secondary,
              size: 24,
            ),
      onPressed: isSaving ? null : onPressed,
      // Se dice "copia" a propósito: Syncora no sigue playlists remotas, las
      // copia (ver `save_collection_service.dart`), y el usuario tiene que
      // saber que lo guardado no se va a actualizar solo.
      tooltip: 'Guardar una copia en mi biblioteca',
    );
  }
}
