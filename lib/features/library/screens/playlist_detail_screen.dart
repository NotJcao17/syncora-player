import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/playlist_cover_widget.dart';
import '../../../core/widgets/track_tile.dart';
import '../../../core/utils/contributor_resolver.dart';
import '../../../data/apis/deezer_api.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../../data/models/deezer/deezer_track.dart';
import '../../../data/sync/sync_service.dart';
import '../../search/search_ranking.dart';
import '../../download/widgets/download_header_button.dart';
import '../../player/audio_engine/audio_engine_state.dart';

import '../../player/player_models.dart';
import '../../player/player_providers.dart';
import '../import_export/playlist_import_export_service.dart';

/// Pantalla de Detalle de Playlist (`/playlist/:id`) conectada a la base de datos Drift.
class PlaylistDetailScreen extends ConsumerStatefulWidget {
  final String playlistId;

  const PlaylistDetailScreen({
    super.key,
    required this.playlistId,
  });

  @override
  ConsumerState<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  Playlist? _playlist;
  bool _isLoadingHeader = true;
  bool _showAddSongsSearch = false;
  final TextEditingController _addSongsController = TextEditingController();
  List<DeezerTrack> _searchResults = [];
  bool _isSearchingSongs = false;
  Color? _dominantColor;
  String? _extractedCoverUrl;

  @override
  void initState() {
    super.initState();
    _loadPlaylistHeader();
  }

  @override
  void dispose() {
    _addSongsController.dispose();
    super.dispose();
  }

  void _extractPalette(String coverUrl) async {
    if (coverUrl.isEmpty || _extractedCoverUrl == coverUrl) return;
    _extractedCoverUrl = coverUrl;
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        NetworkImage(coverUrl),
        maximumColorCount: 8,
      );
      final color = palette.darkVibrantColor?.color ?? palette.dominantColor?.color;
      if (mounted && color != null) {
        setState(() {
          _dominantColor = color;
        });
      }
    } catch (_) {}
  }

  Future<void> _performAddSongsSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearchingSongs = false;
      });
      return;
    }

    setState(() => _isSearchingSongs = true);
    try {
      final deezerApi = ref.read(deezerApiProvider);
      final res = await deezerApi.search(trimmed, type: DeezerSearchType.track);
      if (mounted) {
        setState(() {
          // Misma lógica de ranking del buscador real (pestaña "Canciones"),
          // con el filtro "Popular" siempre activo y sin exponer el toggle —
          // este mini-buscador es para agregar canciones rápido, no para
          // explorar rarezas/covers.
          _searchResults = res.tracks.where(SearchRanking.isPopularTrack).toList();
          _isSearchingSongs = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isSearchingSongs = false);
    }
  }

  Future<bool> _executeRemoteMutation(Future<void> Function() remoteTask) async {
    final dao = ref.read(playlistDaoProvider);
    if (_playlist != null && _playlist!.remoteId != null && !_playlist!.isLiked) {
      try {
        final client = Supabase.instance.client;
        final res = await client
            .from('playlists')
            .select('id')
            .eq('id', _playlist!.remoteId!)
            .maybeSingle();
        if (res == null) {
          if (mounted) {
            AppToast.show(context, message: 'La playlist ya no existe en la nube');
            await dao.deletePlaylist(_playlist!.id);
          }
          return false;
        }
      } catch (_) {}
    }

    try {
      await remoteTask();
      return true;
    } catch (e) {
      if (mounted) {
        AppToast.show(context, message: 'La playlist ya no existe en la nube');
        if (_playlist != null && !_playlist!.isLiked) {
          await dao.deletePlaylist(_playlist!.id);
        }
      }
      return false;
    }
  }

  Future<void> _loadPlaylistHeader() async {
    final dao = ref.read(playlistDaoProvider);
    if (widget.playlistId == 'liked') {
      final liked = await dao.getLikedPlaylist();
      if (mounted) {
        setState(() {
          _playlist = liked;
          _isLoadingHeader = false;
        });
        if (liked.remoteId != null) {
          ref.read(syncServiceProvider).syncPlaylistDetail(liked.remoteId!, force: false);
        }
      }
    } else {
      final id = int.tryParse(widget.playlistId) ?? 0;
      final pl = await dao.getPlaylistById(id);
      if (mounted) {
        setState(() {
          _playlist = pl;
          _isLoadingHeader = false;
        });
        if (pl?.remoteId != null) {
          ref.read(syncServiceProvider).syncPlaylistDetail(pl!.remoteId!, force: false);
        }
      }
    }
  }

  Future<void> _exportPlaylist(List<PlaylistTrack> tracks) async {
    if (_playlist == null || tracks.isEmpty) {
      AppToast.show(context, message: 'No hay canciones para exportar.');
      return;
    }

    final deezerApi = ref.read(deezerApiProvider);
    final service = PlaylistImportExportService(deezerApi);
    final tracksData = tracks
        .map((t) => {
              'title': t.title,
              'artist': t.artistName,
              'album': t.albumName,
              'duration_ms': t.durationMs,
            })
        .toList();

    final csvContent = service.exportToCsv(tracksData);
    final fileName = '${_playlist!.title.replaceAll(RegExp(r'[^\w\s\-]'), '')}.csv';

    try {
      if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        final downloadsDir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
        final file = File('${downloadsDir.path}/$fileName');
        await file.writeAsString(csvContent);
        await Clipboard.setData(ClipboardData(text: csvContent));
        if (mounted) {
          AppToast.show(
            context,
            message: 'Playlist exportada a: ${file.path}',
          );
        }
      } else {
        // ignore: deprecated_member_use
        await Share.shareXFiles([
          XFile.fromData(
            Uint8List.fromList(csvContent.codeUnits),
            name: fileName,
            mimeType: 'text/csv',
          ),
        ]);
        if (mounted) {
          AppToast.show(context, message: 'Playlist exportada con éxito');
        }
      }
    } catch (e) {
      await Clipboard.setData(ClipboardData(text: csvContent));
      if (mounted) {
        AppToast.show(context, message: 'Exportación copiada al portapapeles (${tracks.length} canciones)');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(syncoraPlayerControllerProvider.notifier);
    final currentTrack = ref.watch(currentTrackProvider);
    final isPlaying = ref.watch(isPlayingProvider);
    final isDesktop = MediaQuery.of(context).size.width >= 768;
    final playlistDao = ref.watch(playlistDaoProvider);
    final playlistStream = widget.playlistId == 'liked'
        ? playlistDao.watchLikedPlaylist()
        : playlistDao.watchPlaylistById(int.tryParse(widget.playlistId) ?? 0);

    if (_isLoadingHeader) {
      return const Scaffold(
        backgroundColor: AppTheme.background,
        body: Center(child: CircularProgressIndicator(color: AppTheme.primary)),
      );
    }

    return StreamBuilder<Playlist?>(
      stream: playlistStream,
      initialData: _playlist,
      builder: (context, playlistSnapshot) {
        final playlist = playlistSnapshot.data;
        if (playlist != null) {
          _playlist = playlist;
        }

        if (playlist == null) {
          return Scaffold(
            backgroundColor: AppTheme.background,
            body: ErrorStateWidget(
              title: 'Playlist eliminada',
              message: 'Esta playlist ha sido eliminada de la nube.',
              retryLabel: 'Volver a la biblioteca',
              onRetry: () {
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go('/library');
                }
              },
            ),
          );
        }

        final isLiked = playlist.isLiked;
        final dominantGradientColor = _dominantColor?.withValues(alpha: 0.35) ?? AppTheme.surfaceHover.withValues(alpha: 0.3);

        return Scaffold(
          backgroundColor: AppTheme.background,
          body: StreamBuilder<List<PlaylistTrack>>(
            stream: playlistDao.watchTracksOrdered(playlist.id),
        builder: (ctx, snapshot) {
          final tracks = snapshot.data ?? [];
          final syncoraTracks = tracks
              .map((t) {
                var parsedArtists = SyncoraArtistRef.decodeList(t.contributorsJson);
                if (parsedArtists.isEmpty && t.artistName.contains(', ')) {
                  final names = t.artistName.split(', ');
                  parsedArtists = [
                    for (int i = 0; i < names.length; i++)
                      SyncoraArtistRef(id: i == 0 ? t.artistId : 0, name: names[i].trim()),
                  ];
                } else if (parsedArtists.isEmpty && (t.artistId != 0 || t.artistName.isNotEmpty)) {
                  parsedArtists = [SyncoraArtistRef(id: t.artistId, name: t.artistName)];
                }

                return SyncoraTrack(
                  id: t.trackId.toString(),
                  title: t.title,
                  artist: t.artistName,
                  artists: parsedArtists,
                  artistId: t.artistId,
                  album: t.albumName,
                  albumId: t.albumId,
                  duration: Duration(milliseconds: t.durationMs),
                  artUri: t.coverUrl.isNotEmpty ? Uri.tryParse(t.coverUrl) : null,
                );
              })
              .toList();

          if (playlist.coverUrl != null && playlist.coverUrl!.isNotEmpty) {
            _extractPalette(playlist.coverUrl!);
          } else if (syncoraTracks.isNotEmpty && syncoraTracks.first.coverUrl.isNotEmpty) {
            _extractPalette(syncoraTracks.first.coverUrl);
          }

          final playerState = ref.watch(playerStateProvider);
          final playlistContextId = 'playlist_${playlist.id}';
          final isCurrentContext = playerState.activeContextId == playlistContextId;
          final isBufferingOrPlaying = isPlaying ||
              (playerState.engine.processingState == AudioProcessingState.loading ||
               playerState.engine.processingState == AudioProcessingState.buffering);
          final showPauseHeader = isCurrentContext && isBufferingOrPlaying;

          return Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  dominantGradientColor,
                  AppTheme.background,
                  AppTheme.background,
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: RefreshIndicator(
                    onRefresh: () async {
                      if (playlist.remoteId != null) {
                        await ref.read(syncServiceProvider).syncPlaylistDetail(playlist.remoteId!, force: true);
                      }
                    },
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.only(
                        top: MediaQuery.of(context).padding.top + 56,
                        left: isDesktop ? 32 : 12,
                        right: isDesktop ? 32 : 12,
                        bottom: 40,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 8),

                          if (isDesktop)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Container(
                                  width: 220,
                                  height: 220,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(16),
                                    boxShadow: AppTheme.glowShadow,
                                  ),
                                  child: PlaylistCoverWidget(
                                    coverUrl: playlist.coverUrl,
                                    playlistId: playlist.id,
                                    tracks: syncoraTracks,
                                    isLiked: isLiked,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                const SizedBox(width: 28),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'PLAYLIST',
                                        style: TextStyle(
                                          color: AppTheme.secondary,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 1.5,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        playlist.title,
                                        style: const TextStyle(
                                          color: AppTheme.primary,
                                          fontSize: 44,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: -1,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        playlist.description ?? 'Sin descripción',
                                        style: const TextStyle(color: AppTheme.secondary, fontSize: 14),
                                      ),
                                      const SizedBox(height: 14),
                                      Text(
                                        '${tracks.length} canciones',
                                        style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            )
                          else
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Center(
                                  child: Container(
                                    width: 180,
                                    height: 180,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(20),
                                      boxShadow: AppTheme.glowHighShadow,
                                    ),
                                    child: PlaylistCoverWidget(
                                      coverUrl: playlist.coverUrl,
                                      playlistId: playlist.id,
                                      tracks: syncoraTracks,
                                      isLiked: isLiked,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  playlist.title,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: AppTheme.primary,
                                    fontSize: 28,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -0.5,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  playlist.description ?? 'Sin descripción',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  '${tracks.length} canciones',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                                ),
                              ],
                            ),

                          const SizedBox(height: 16),

                          // Actions row
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              mainAxisAlignment: isDesktop ? MainAxisAlignment.start : MainAxisAlignment.center,

                            children: [
                              if (syncoraTracks.isNotEmpty) ...[
                                _HeaderPlayButton(
                                  isPlaying: showPauseHeader,
                                  onPressed: () {
                                    if (showPauseHeader) {
                                      controller.pause();
                                    } else if (isCurrentContext) {
                                      controller.play();
                                    } else {
                                      controller.setQueue(syncoraTracks, startIndex: 0, activeContextId: playlistContextId);
                                      controller.play();
                                    }
                                  },
                                ),
                                const SizedBox(width: 8),
                                DownloadHeaderButton(
                                  title: playlist.title,
                                  tracks: syncoraTracks,
                                ),
                                const SizedBox(width: 12),
                              ],

                              if (isDesktop && playlist.remoteId != null) ...[
                                IconButton(
                                  icon: const Icon(Icons.refresh),
                                  color: AppTheme.secondary,
                                  onPressed: () {
                                    if (playlist.remoteId != null) {
                                      ref.read(syncServiceProvider).syncPlaylistDetail(playlist.remoteId!, force: true);
                                    }
                                  },
                                  tooltip: 'Sincronizar playlist',
                                ),
                                const SizedBox(width: 8),
                              ],
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _showAddSongsSearch ? AppTheme.surfaceHover : AppTheme.surface,
                                foregroundColor: AppTheme.primary,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              ),
                              onPressed: () {
                                setState(() => _showAddSongsSearch = !_showAddSongsSearch);
                              },
                              icon: Icon(_showAddSongsSearch ? AppIcons.broken(SolarIcons.CloseCircle) : AppIcons.broken(SolarIcons.AddCircle), size: 18),
                              label: Text(_showAddSongsSearch ? 'Cerrar buscador' : 'Agregar canciones', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: Icon(AppIcons.broken(SolarIcons.Export), color: AppTheme.secondary, size: 22),
                              onPressed: () => _exportPlaylist(tracks),
                              tooltip: 'Exportar playlist (CSV)',
                            ),
                            const SizedBox(width: 8),
                            if (!isLiked)
                              IconButton(
                                icon: Icon(AppIcons.broken(SolarIcons.TrashBinMinimalistic), color: AppTheme.secondary, size: 20),
                                onPressed: () async {
                                  final confirm = await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      backgroundColor: AppTheme.surface,
                                      title: const Text('¿Eliminar playlist?', style: TextStyle(color: AppTheme.primary)),
                                      content: const Text('Esta acción no se puede deshacer.', style: TextStyle(color: AppTheme.secondary)),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
                                        ElevatedButton(
                                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                                          onPressed: () => Navigator.pop(ctx, true),
                                          child: const Text('Eliminar'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirm == true) {
                                    await _executeRemoteMutation(() async {
                                      if (playlist.remoteId != null) {
                                        final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
                                        await supabaseRepo.deletePlaylist(playlist.remoteId!);
                                      }
                                    });
                                    if (!playlist.isLiked) {
                                      await playlistDao.deletePlaylist(playlist.id);
                                    }
                                    if (context.mounted && context.canPop()) context.pop();
                                  }
                                },
                                tooltip: 'Eliminar playlist',
                              ),
                          ],
                        ),
                      ),


                        const SizedBox(height: 12),

                        // Buscador inline de canciones para agregar a esta playlist
                        if (_showAddSongsSearch || tracks.isEmpty) ...[
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: AppTheme.surface,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: AppTheme.surfaceHover),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Buscar canciones para agregar',
                                  style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _addSongsController,
                                  onChanged: (val) => _performAddSongsSearch(val),
                                  style: const TextStyle(color: AppTheme.primary),
                                  decoration: InputDecoration(
                                    hintText: 'Escribe nombre de canción o artista...',
                                    hintStyle: TextStyle(color: AppTheme.secondary.withValues(alpha: 0.7)),
                                    prefixIcon: Icon(AppIcons.broken(SolarIcons.Magnifer), color: AppTheme.secondary, size: 18),
                                    suffixIcon: _isSearchingSongs
                                        ? const Padding(
                                            padding: EdgeInsets.all(12),
                                            child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primary)),
                                          )
                                        : (_addSongsController.text.isNotEmpty
                                            ? IconButton(
                                                icon: Icon(AppIcons.broken(SolarIcons.CloseCircle), color: AppTheme.secondary, size: 18),
                                                onPressed: () {
                                                  _addSongsController.clear();
                                                  _performAddSongsSearch('');
                                                },
                                              )
                                            : null),
                                    filled: true,
                                    fillColor: AppTheme.background,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                  ),
                                ),
                                if (_searchResults.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  ListView.builder(
                                    shrinkWrap: true,
                                    physics: const NeverScrollableScrollPhysics(),
                                    itemCount: _searchResults.length > 8 ? 8 : _searchResults.length,
                                    itemBuilder: (ctx, i) {
                                      final track = _searchResults[i];
                                      return ListTile(
                                        contentPadding: EdgeInsets.zero,
                                        leading: ClipRRect(
                                          borderRadius: BorderRadius.circular(6),
                                          child: CachedNetworkImage(imageUrl: track.coverUrl, width: 40, height: 40, fit: BoxFit.cover),
                                        ),
                                        title: Text(track.title, style: const TextStyle(color: AppTheme.primary, fontSize: 14, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                                        subtitle: Text(track.artistName, style: const TextStyle(color: AppTheme.secondary, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                                        trailing: IconButton(
                                          icon: Icon(AppIcons.broken(SolarIcons.AddCircle), color: AppTheme.primary, size: 22),
                                          onPressed: () async {
                                            final ok = await _executeRemoteMutation(() async {
                                              String? remoteId = playlist.remoteId;
                                              final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
                                              if (remoteId == null) {
                                                final res = await supabaseRepo.createPlaylist(
                                                  title: playlist.title,
                                                  description: playlist.description,
                                                  isPublic: playlist.isPublic,
                                                  isLiked: playlist.isLiked,
                                                );
                                                remoteId = res['id']?.toString();
                                                if (remoteId != null) {
                                                  await playlistDao.updatePlaylist(playlist.copyWith(remoteId: Value(remoteId)));
                                                }
                                              }

                                              if (remoteId != null) {
                                                await supabaseRepo.addTrackToPlaylist(remoteId, {
                                                  'track_id': track.id,
                                                  'artist_id': track.artistId,
                                                  'album_id': track.albumId,
                                                  'title': track.title,
                                                  'artist_name': track.artistName,
                                                  'album_name': track.albumTitle,
                                                  'cover_url': track.coverUrl,
                                                  'duration_ms': track.durationSec * 1000,
                                                });
                                              }
                                            });

                                            if (!ok) return;

                                            final currentPl = await playlistDao.getPlaylistById(playlist.id);
                                            if (currentPl == null) return;

                                            final contributors = await resolveDeezerTrackContributors(
                                              ref.read(deezerApiProvider),
                                              track,
                                            );
                                            await playlistDao.addTrackToPlaylist(
                                              playlistId: playlist.id,
                                              trackId: track.id,
                                              artistId: track.artistId,
                                              albumId: track.albumId,
                                              title: track.title,
                                              artistName: track.artistName,
                                              albumName: track.albumTitle,
                                              coverUrl: track.coverUrl,
                                              durationMs: track.durationSec * 1000,
                                              contributorsJson: SyncoraArtistRef.encodeList(contributors),
                                            );
                                            if (!context.mounted) return;
                                            AppToast.show(context, message: '"${track.title}" agregada a la playlist');
                                          },
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        const SizedBox(height: 16),

                        if (tracks.isEmpty && !_showAddSongsSearch)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Center(
                              child: Text(
                                'Esta playlist está vacía.\nUsa el buscador de arriba para agregar canciones.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: AppTheme.secondary, height: 1.5),
                              ),
                            ),
                          )
                        else ...[
                          if (isDesktop && syncoraTracks.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              child: Row(
                                children: [
                                  const SizedBox(width: 28, child: Text('#', style: TextStyle(color: AppTheme.secondary, fontSize: 12, fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
                                  const SizedBox(width: 8),
                                  const Expanded(flex: 3, child: Padding(padding: EdgeInsets.only(left: 60), child: Text('TÍTULO', style: TextStyle(color: AppTheme.secondary, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.2)))),
                                  const SizedBox(width: 16),
                                  const Expanded(flex: 2, child: Text('ÁLBUM', style: TextStyle(color: AppTheme.secondary, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.2))),
                                  const SizedBox(width: 12),
                                  SizedBox(width: 50, child: Align(alignment: Alignment.centerRight, child: Icon(AppIcons.broken(SolarIcons.ClockCircle), color: AppTheme.secondary, size: 16))),
                                  const SizedBox(width: 52),
                                ],
                              ),
                            ),
                            const Divider(height: 12, color: AppTheme.surfaceHover),
                          ],
                          ListView.builder(
                            padding: EdgeInsets.zero,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: syncoraTracks.length,
                            itemBuilder: (ctx, i) {
                              final track = syncoraTracks[i];
                              final playlistTrack = tracks[i];
                              // Fase 7.A: el modelo de cola dual ya no tiene un índice estable
                              // sobre "la cola" para desambiguar duplicados dentro de la misma
                              // playlist (regresión aceptada y documentada, ver plan_fase_7.md).
                              final isPlayingTrack = currentTrack?.id == track.id;

                              return TrackTile(
                                track: track,
                                index: i,
                                isPlaying: isPlayingTrack,
                                showAlbum: true,
                                onTap: () {
                                  controller.setQueue(syncoraTracks, startIndex: i, activeContextId: playlistContextId);
                                },
                                onRemove: () async {
                                  final ok = await _executeRemoteMutation(() async {
                                    if (playlist.remoteId != null) {
                                      final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
                                      await supabaseRepo.removeTrackFromPlaylist(playlist.remoteId!, playlistTrack.trackId);
                                    }
                                  });
                                  if (!ok) return;
                                  final currentPl = await playlistDao.getPlaylistById(playlist.id);
                                  if (currentPl != null) {
                                    await playlistDao.removeTrackEntry(playlistTrack.id);
                                  }
                                },
                                onAddToQueue: () => controller.addToQueue(track),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),

                Positioned(
                  top: MediaQuery.of(context).padding.top + 8,
                  left: 16,
                  right: 16,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withValues(alpha: 0.35),
                        ),
                        child: IconButton(
                          icon: Icon(AppIcons.broken(SolarIcons.AltArrowLeft), color: AppTheme.primary, size: 20),
                          onPressed: () => context.pop(),
                          padding: EdgeInsets.zero,
                        ),
                      ),
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withValues(alpha: 0.35),
                        ),
                        child: IconButton(
                          icon: Icon(AppIcons.broken(SolarIcons.Magnifer), color: AppTheme.primary, size: 18),
                          onPressed: () => context.push('/search'),
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  },
);
  }
}

class _HeaderPlayButton extends StatefulWidget {
  final bool isPlaying;
  final VoidCallback onPressed;

  const _HeaderPlayButton({
    required this.isPlaying,
    required this.onPressed,
  });

  @override
  State<_HeaderPlayButton> createState() => _HeaderPlayButtonState();
}

class _HeaderPlayButtonState extends State<_HeaderPlayButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedScale(
        scale: _isHovered ? 1.08 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.primary,
            boxShadow: _isHovered ? AppTheme.glowHighShadow : AppTheme.glowShadow,
          ),
          child: IconButton(
            icon: Icon(
              widget.isPlaying ? AppIcons.broken(SolarIcons.Pause) : AppIcons.outline(SolarIcons.Play),
              color: AppTheme.background,
              size: 26,
            ),
            onPressed: widget.onPressed,
          ),
        ),
      ),
    );
  }
}
