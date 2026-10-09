import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/playlist_cover_widget.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../auth/auth_provider.dart';
import '../../auth/local_mode_provider.dart';
import '../../catalog/widgets/collection_scaffold.dart';
import '../../catalog/widgets/save_collection_button.dart';
import '../../player/player_models.dart';
import '../services/playlist_share_service.dart';

final _uuidPattern = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false);

/// Una playlist compartida, leída de Supabase (RLS: solo las públicas).
class SharedPlaylistData {
  final String remoteId;
  final String ownerId;
  final String title;
  final String? description;
  final String? coverUrl;
  final List<SyncoraTrack> tracks;

  const SharedPlaylistData({
    required this.remoteId,
    required this.ownerId,
    required this.title,
    required this.description,
    required this.coverUrl,
    required this.tracks,
  });
}

/// Fila de `playlist_tracks` -> pista del reproductor.
SyncoraTrack sharedTrackToSyncora(Map<String, dynamic> t) {
  final artistName = t['artist_name'] as String? ?? '';
  final artistId = (t['artist_id'] as num?)?.toInt() ?? 0;
  var artists = SyncoraArtistRef.decodeList(t['contributors_json'] as String?);
  if (artists.isEmpty && (artistId != 0 || artistName.isNotEmpty)) {
    artists = [SyncoraArtistRef(id: artistId, name: artistName)];
  }
  final cover = t['cover_url'] as String? ?? '';
  return SyncoraTrack(
    id: (t['track_id'] as num).toString(),
    title: t['title'] as String? ?? '',
    artist: artistName,
    artists: artists,
    artistId: artistId,
    album: t['album_name'] as String?,
    albumId: (t['album_id'] as num?)?.toInt(),
    duration: Duration(milliseconds: (t['duration_ms'] as num?)?.toInt() ?? 0),
    genre: t['genre'] as String?,
    artUri: cover.isNotEmpty ? Uri.tryParse(cover) : null,
  );
}

/// `null` = no existe o su dueño ya no la comparte.
final sharedPlaylistProvider =
    FutureProvider.autoDispose.family<SharedPlaylistData?, String>((ref, remoteId) async {
  final repo = ref.watch(supabasePlaylistRepositoryProvider);
  final row = await repo.fetchPublicPlaylist(remoteId);
  if (row == null) return null;
  final trackRows = await repo.fetchPlaylistTracks(remoteId);
  final seen = <int>{};
  return SharedPlaylistData(
    remoteId: remoteId,
    ownerId: row['user_id']?.toString() ?? '',
    title: row['title'] as String? ?? 'Playlist',
    description: row['description'] as String?,
    coverUrl: row['cover_url'] as String?,
    tracks: [
      for (final t in trackRows)
        if (t['track_id'] is num && seen.add((t['track_id'] as num).toInt())) sharedTrackToSyncora(t),
    ],
  );
});

/// Playlist que alguien compartió por enlace (`syncoraplayer.app/playlist/<id>`
/// -> `syncoraplayer://playlist/<id>` -> `/shared-playlist/<id>`).
///
/// Si ya está en la biblioteca (propia o guardada), salta a ella. Si no, la
/// muestra para escucharla y ofrece guardarla: con cuenta queda en la
/// biblioteca de solo lectura y se mantiene al día con la original; sin cuenta
/// se guarda una copia, porque guardar de verdad necesita la nube.
class SharedPlaylistScreen extends ConsumerStatefulWidget {
  final String remoteId;

  const SharedPlaylistScreen({super.key, required this.remoteId});

  @override
  ConsumerState<SharedPlaylistScreen> createState() => _SharedPlaylistScreenState();
}

class _SharedPlaylistScreenState extends ConsumerState<SharedPlaylistScreen> {
  bool _checkedLocal = false;
  bool _isSaving = false;

  String get _id => widget.remoteId.toLowerCase();

  @override
  void initState() {
    super.initState();
    _openLocalIfSaved();
  }

  Future<void> _openLocalIfSaved() async {
    if (_uuidPattern.hasMatch(_id)) {
      final local = await ref.read(playlistDaoProvider).getPlaylistByRemoteId(_id);
      if (local != null && mounted) {
        context.replace('/playlist/${local.id}');
        return;
      }
    }
    if (mounted) setState(() => _checkedLocal = true);
  }

  Future<void> _save(SharedPlaylistData data) async {
    if (_isSaving) return;
    if (!ref.read(canEditProvider)) {
      AppToast.show(context, message: 'Sin conexión: no se puede guardar ahora.');
      return;
    }
    setState(() => _isSaving = true);
    try {
      final localId = await followSharedPlaylist(ref, data.remoteId);
      if (!mounted) return;
      if (localId == null) {
        AppToast.show(context, message: 'Esta playlist ya no está disponible.');
        ref.invalidate(sharedPlaylistProvider(_id));
        return;
      }
      AppToast.show(context, message: 'Guardada en tu biblioteca');
      context.replace('/playlist/$localId');
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        message: e.toString().contains('followed_playlist_limit')
            ? 'Llegaste al límite de playlists guardadas de otras personas.'
            : 'No se pudo guardar. Revisa tu conexión.',
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// Descargar algo que no está en la biblioteca dejaría pistas sin colección.
  Future<bool> _saveBeforeDownload(SharedPlaylistData data, bool isLocalMode) async {
    if (isLocalMode) {
      return await copySharedTracks(
            context,
            ref,
            remoteId: data.remoteId,
            title: data.title,
            description: data.description,
            tracks: data.tracks,
          ) !=
          null;
    }
    await _save(data);
    return false; // `_save` ya abrió la playlist guardada; ahí se descarga.
  }

  @override
  Widget build(BuildContext context) {
    if (!_uuidPattern.hasMatch(_id)) {
      return const Scaffold(
        backgroundColor: AppTheme.background,
        body: ErrorStateWidget(title: 'Enlace no válido', message: 'Este enlace de playlist está incompleto.'),
      );
    }
    if (!_checkedLocal) {
      return const Scaffold(backgroundColor: AppTheme.background);
    }

    final async = ref.watch(sharedPlaylistProvider(_id));
    return async.when(
      loading: () => const Scaffold(
        backgroundColor: AppTheme.background,
        body: Center(child: CircularProgressIndicator(color: AppTheme.primary)),
      ),
      error: (_, _) => Scaffold(
        backgroundColor: AppTheme.background,
        body: ErrorStateWidget(
          message: 'No pudimos cargar la playlist. Revisa tu conexión.',
          onRetry: () => ref.invalidate(sharedPlaylistProvider(_id)),
        ),
      ),
      data: (data) {
        if (data == null) {
          return const Scaffold(
            backgroundColor: AppTheme.background,
            body: ErrorStateWidget(
              title: 'Esta playlist no está disponible',
              message: 'Puede que su dueño haya dejado de compartirla o que la haya borrado.',
            ),
          );
        }

        final isLocalMode = ref.watch(localModeProvider);
        final isMine = !isLocalMode && ref.watch(currentUserProvider)?.id == data.ownerId;
        final count = data.tracks.length;
        final cover = data.coverUrl ?? '';
        final paletteUrl = cover.startsWith('http') ? cover : (data.tracks.isNotEmpty ? data.tracks.first.coverUrl : '');

        return CollectionScaffold(
          label: 'Playlist compartida',
          title: data.title,
          subtitle: '$count ${count == 1 ? 'canción' : 'canciones'}',
          coverUrl: paletteUrl,
          coverOverride: PlaylistCoverWidget(coverUrl: data.coverUrl, tracks: data.tracks),
          tracks: data.tracks,
          contextId: 'shared_playlist_${data.remoteId}',
          onRefresh: () async => ref.invalidate(sharedPlaylistProvider(_id)),
          emptyMessage: 'Esta playlist todavía no tiene canciones.',
          onBeforeDownload: isMine ? null : () => _saveBeforeDownload(data, isLocalMode),
          actions: [
            if (isLocalMode)
              SaveCollectionButton(
                sourceRef: sharedPlaylistSourceRef(data.remoteId),
                title: data.title,
                description: data.description,
                tracks: data.tracks,
              )
            else if (!isMine)
              IconButton(
                tooltip: 'Guardar en mi biblioteca',
                onPressed: _isSaving ? null : () => _save(data),
                icon: _isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.secondary),
                      )
                    : Icon(AppIcons.broken(SolarIcons.AddCircle), color: AppTheme.secondary, size: 24),
              ),
          ],
        );
      },
    );
  }
}
