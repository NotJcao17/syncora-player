import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/track_tile.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../player/player_models.dart';
import '../../player/player_providers.dart';
import '../download_provider.dart';

/// Pantalla de administración de pistas descargadas localmente (`/downloads`).
class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 768;
    final downloadedTracksAsync = ref.watch(watchAllDownloadedTracksProvider);
    final dao = ref.read(downloadedTrackDaoProvider);
    final controller = ref.watch(syncoraPlayerControllerProvider.notifier);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: EdgeInsets.fromLTRB(
                isDesktop ? 32 : 20,
                isDesktop ? 20 : 12,
                isDesktop ? 32 : 20,
                10,
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(AppIcons.broken(SolarIcons.AltArrowLeft), color: AppTheme.primary, size: 22),
                    onPressed: () => context.pop(),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Música Descargada',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        color: AppTheme.primary,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  downloadedTracksAsync.when(
                    data: (tracks) => tracks.isNotEmpty
                        ? TextButton.icon(
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  backgroundColor: AppTheme.surface,
                                  title: const Text('¿Eliminar todas las descargas?', style: TextStyle(color: AppTheme.primary)),
                                  content: const Text('Se borrarán todos los archivos de audio locales.', style: TextStyle(color: AppTheme.secondary)),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
                                    ElevatedButton(
                                      style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text('Eliminar todo'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                await dao.deleteAll();
                                if (context.mounted) {
                                  AppToast.show(context, message: 'Todas las descargas han sido eliminadas');
                                }
                              }
                            },
                            icon: const Icon(Icons.delete_sweep, color: Colors.redAccent, size: 18),
                            label: const Text('Vaciar', style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                          )
                        : const SizedBox.shrink(),
                    loading: () => const SizedBox.shrink(),
                    error: (_, stack) => const SizedBox.shrink(),

                  ),
                ],
              ),
            ),

            // Buscador inline
            Padding(
              padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20, vertical: 8),
              child: TextField(
                controller: _searchController,
                onChanged: (val) => setState(() => _searchQuery = val.trim().toLowerCase()),
                style: const TextStyle(color: AppTheme.primary),
                decoration: InputDecoration(
                  hintText: 'Buscar en descargas...',
                  hintStyle: TextStyle(color: AppTheme.secondary.withValues(alpha: 0.7)),
                  prefixIcon: Icon(AppIcons.broken(SolarIcons.Magnifer), color: AppTheme.secondary, size: 18),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: Icon(AppIcons.broken(SolarIcons.CloseCircle), color: AppTheme.secondary, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: AppTheme.surface,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
            ),

            const SizedBox(height: 8),

            // Lista de descargas
            Expanded(
              child: downloadedTracksAsync.when(
                data: (tracks) {
                  final filtered = tracks.where((DownloadedTrack t) {
                    if (t.downloadState != 2) return false;
                    if (_searchQuery.isEmpty) return true;
                    final title = t.title.toLowerCase();
                    final artist = t.artistName.toLowerCase();
                    final album = t.albumName.toLowerCase();
                    return title.contains(_searchQuery) || artist.contains(_searchQuery) || album.contains(_searchQuery);
                  }).toList();

                  if (filtered.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            AppIcons.broken(SolarIcons.CloudDownload),
                            size: 64,
                            color: AppTheme.secondary,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _searchQuery.isNotEmpty ? 'Sin resultados para "$_searchQuery"' : 'No hay descargas guardadas',
                            style: const TextStyle(
                              color: AppTheme.primary,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (_searchQuery.isEmpty)
                            const Text(
                              'Descarga playlists o álbumes desde la biblioteca',
                              style: TextStyle(color: AppTheme.secondary, fontSize: 13),
                            ),
                        ],
                      ),
                    );
                  }

                  final syncoraTracks = filtered.map<SyncoraTrack>((DownloadedTrack t) {
                    return SyncoraTrack(
                      id: t.trackId.toString(),
                      title: t.title,
                      artist: t.artistName,
                      album: t.albumName,
                      duration: Duration(milliseconds: t.durationMs),
                      artUri: t.localCoverPath != null ? Uri.file(t.localCoverPath!) : null,
                    );
                  }).toList();


                  final currentTrack = ref.watch(currentTrackProvider);

                  return ListView.builder(
                    padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20, vertical: 8),
                    itemCount: syncoraTracks.length,
                    itemBuilder: (ctx, i) {
                      final track = syncoraTracks[i];
                      final downloadedTrack = filtered[i];
                      final isPlayingTrack = currentTrack?.id == track.id;

                      return Dismissible(
                        key: Key('downloaded_track_${downloadedTrack.trackId}'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          decoration: BoxDecoration(
                            color: Colors.redAccent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.delete_outline, color: Colors.white, size: 24),
                        ),
                        confirmDismiss: (dir) async {
                          await dao.deleteByTrackId(downloadedTrack.trackId);
                          if (context.mounted) {
                            AppToast.show(context, message: 'Descarga eliminada');
                          }
                          return true;
                        },
                        child: TrackTile(
                          track: track,
                          index: i,
                          isPlaying: isPlayingTrack,
                          isDownloaded: true,
                          showAlbum: true,
                          onTap: () {
                            controller.setQueue(syncoraTracks, startIndex: i, activeContextId: 'downloads');
                          },
                          onRemove: () async {
                            await dao.deleteByTrackId(downloadedTrack.trackId);
                            if (context.mounted) {
                              AppToast.show(context, message: 'Descarga eliminada');
                            }
                          },
                        ),
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator(color: AppTheme.primary)),
                error: (err, stack) => Center(
                  child: Text('Error al cargar descargas: $err', style: const TextStyle(color: Colors.redAccent)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
