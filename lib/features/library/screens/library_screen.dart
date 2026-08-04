import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../import_export/playlist_import_export_service.dart';

/// Pantalla de Biblioteca conectada a la base de datos local Drift y servicio de Import/Export.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  String _selectedFilter = 'Playlists';
  final List<String> _filters = const ['Playlists', 'Álbumes'];

  void _showCreatePlaylistDialog(BuildContext context) {
    final titleController = TextEditingController();
    final descController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Nueva Playlist', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              autofocus: true,
              style: const TextStyle(color: AppTheme.primary),
              decoration: const InputDecoration(
                labelText: 'Nombre de la playlist',
                labelStyle: TextStyle(color: AppTheme.secondary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppTheme.surfaceHover)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppTheme.primary)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descController,
              style: const TextStyle(color: AppTheme.primary),
              decoration: const InputDecoration(
                labelText: 'Descripción (opcional)',
                labelStyle: TextStyle(color: AppTheme.secondary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppTheme.surfaceHover)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppTheme.primary)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar', style: TextStyle(color: AppTheme.secondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: AppTheme.background,
            ),
            onPressed: () async {
              final title = titleController.text.trim();
              if (title.isNotEmpty) {
                final dao = ref.read(playlistDaoProvider);
                await dao.createPlaylist(
                  title: title,
                  description: descController.text.trim().isEmpty ? null : descController.text.trim(),
                );
                if (ctx.mounted) Navigator.of(ctx).pop();
              }
            },
            child: const Text('Crear', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _importPlaylistFromFile(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'txt'],
    );

    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    String content = '';

    if (file.bytes != null) {
      content = String.fromCharCodes(file.bytes!);
    } else if (file.path != null) {
      content = await File(file.path!).readAsString();
    }

    if (content.isEmpty) return;

    final deezerApi = ref.read(deezerApiProvider);
    final service = PlaylistImportExportService(deezerApi);
    final rawTracks = service.parseFileContent(content);

    if (rawTracks.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se encontraron canciones válidas en el archivo.')),
        );
      }
      return;
    }

    // Create a new playlist for the imported tracks
    final dao = ref.read(playlistDaoProvider);
    final playlistName = file.name.replaceAll(RegExp(r'\.(csv|txt)$'), '');
    final playlistId = await dao.createPlaylist(
      title: 'Importada: $playlistName',
      description: 'Importada desde ${file.name}',
    );

    if (!context.mounted) return;

    // Show progress modal dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        final matched = <dynamic>[];
        final unmatched = <RawImportTrack>[];

        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return StreamBuilder<ImportProgress>(
              stream: service.processImport(
                rawTracks: rawTracks,
                outMatched: matched.cast(),
                outUnmatched: unmatched,
              ),
              builder: (ctx, snapshot) {
                final progress = snapshot.data;
                final isDone = snapshot.connectionState == ConnectionState.done;

                if (isDone) {
                  // Add matched tracks to database playlist
                  Future.microtask(() async {
                    for (final track in matched) {
                      await dao.addTrackToPlaylist(
                        playlistId: playlistId,
                        trackId: track.id,
                        artistId: track.artistId,
                        albumId: track.albumId,
                        title: track.title,
                        artistName: track.artistName,
                        albumName: track.albumTitle,
                        coverUrl: track.coverUrl,
                        durationMs: track.durationSec * 1000,
                      );
                    }
                  });
                }

                return AlertDialog(
                  backgroundColor: AppTheme.surface,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  title: Text(
                    isDone ? 'Importación Completada' : 'Importando canciones...',
                    style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold),
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isDone) ...[
                        LinearProgressIndicator(
                          value: progress?.ratio ?? 0,
                          backgroundColor: AppTheme.surfaceHover,
                          color: AppTheme.primary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Buscando pista ${progress?.current ?? 0} de ${progress?.total ?? rawTracks.length}...',
                          style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          progress?.currentTrackName ?? '',
                          style: const TextStyle(color: AppTheme.primary, fontSize: 12, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ] else ...[
                        const Icon(LucideIcons.checkCircle2, color: Colors.green, size: 48),
                        const SizedBox(height: 16),
                        Text(
                          '${matched.length} encontradas, ${unmatched.length} no encontradas',
                          style: const TextStyle(color: AppTheme.primary, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ],
                  ),
                  actions: [
                    if (isDone)
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primary,
                          foregroundColor: AppTheme.background,
                        ),
                        onPressed: () => Navigator.of(dialogCtx).pop(),
                        child: const Text('Aceptar', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 768;
    final playlistDao = ref.watch(playlistDaoProvider);
    final savedAlbumDao = ref.watch(savedAlbumDaoProvider);

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: Tu Biblioteca + Search & Plus action buttons
          Padding(
            padding: EdgeInsets.fromLTRB(
              isDesktop ? 32 : 20,
              isDesktop ? 20 : 12,
              isDesktop ? 32 : 20,
              10,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Tu Biblioteca',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.primary,
                    letterSpacing: -0.8,
                  ),
                ),
                Row(
                  children: [
                    Tooltip(
                      message: 'Importar desde CSV/TXT',
                      child: IconButton(
                        icon: const Icon(LucideIcons.fileInput, color: AppTheme.primary, size: 20),
                        onPressed: () => _importPlaylistFromFile(context),
                      ),
                    ),
                    Tooltip(
                      message: 'Buscar',
                      child: IconButton(
                        icon: const Icon(LucideIcons.search, color: AppTheme.primary, size: 20),
                        onPressed: () => context.push('/search'),
                      ),
                    ),
                    Tooltip(
                      message: 'Crear playlist',
                      child: IconButton(
                        icon: const Icon(LucideIcons.plus, color: AppTheme.primary, size: 22),
                        onPressed: () => _showCreatePlaylistDialog(context),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const Divider(color: AppTheme.surface, height: 1),
          const SizedBox(height: 12),

          // Píldoras de Filtro
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20, vertical: 2),
            child: Row(
              children: _filters.map((filter) {
                final isSelected = _selectedFilter == filter;
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: ChoiceChip(
                    label: Text(filter),
                    selected: isSelected,
                    onSelected: (val) {
                      if (val) setState(() => _selectedFilter = filter);
                    },
                    selectedColor: AppTheme.primary,
                    backgroundColor: AppTheme.surface,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    labelStyle: TextStyle(
                      color: isSelected ? AppTheme.background : AppTheme.primary,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                    shape: StadiumBorder(
                      side: BorderSide(
                        color: isSelected ? AppTheme.primary : AppTheme.surfaceHover,
                      ),
                    ),
                    showCheckmark: false,
                  ),
                );
              }).toList(),
            ),
          ),

          const SizedBox(height: 16),

          // Lista dinámica de biblioteca
          Expanded(
            child: _selectedFilter == 'Álbumes'
                ? StreamBuilder<List<SavedAlbum>>(
                    stream: savedAlbumDao.watchAllSavedAlbums(),
                    builder: (ctx, snapshot) {
                      final albums = snapshot.data ?? [];
                      if (albums.isEmpty) {
                        return const Center(
                          child: Text(
                            'No tienes álbumes guardados',
                            style: TextStyle(color: AppTheme.secondary),
                          ),
                        );
                      }

                      return ListView.builder(
                        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
                        itemCount: albums.length,
                        itemBuilder: (ctx, i) {
                          final album = albums[i];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: InkWell(
                              onTap: () => context.push('/album/${album.albumId}'),
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                child: Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: SizedBox(
                                        width: 64,
                                        height: 64,
                                        child: CachedNetworkImage(
                                          imageUrl: album.coverUrl,
                                          memCacheWidth: 300,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            album.title,
                                            style: const TextStyle(
                                              color: AppTheme.primary,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            'Álbum • ${album.artistName}',
                                            style: const TextStyle(
                                              color: AppTheme.secondary,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  )
                : StreamBuilder<List<Playlist>>(
                    stream: playlistDao.watchAllPlaylists(),
                    builder: (ctx, snapshot) {
                      final playlists = snapshot.data ?? [];

                      return ListView.builder(
                        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
                        itemCount: playlists.length,
                        itemBuilder: (ctx, i) {
                          final playlist = playlists[i];
                          final isLiked = playlist.isLiked;

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8.0),
                            child: InkWell(
                              onTap: () => context.push('/playlist/${playlist.id}'),
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                child: Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: SizedBox(
                                        width: 64,
                                        height: 64,
                                        child: isLiked
                                            ? Container(
                                                decoration: const BoxDecoration(
                                                  gradient: AppTheme.gradientLiked,
                                                ),
                                                child: const Icon(
                                                  LucideIcons.heart,
                                                  color: Colors.white,
                                                  size: 28,
                                                ),
                                              )
                                            : (playlist.coverUrl != null && playlist.coverUrl!.isNotEmpty)
                                                ? CachedNetworkImage(
                                                    imageUrl: playlist.coverUrl!,
                                                    memCacheWidth: 300,
                                                    fit: BoxFit.cover,
                                                  )
                                                : Container(
                                                    color: AppTheme.surfaceHover,
                                                    child: const Icon(LucideIcons.music, color: AppTheme.muted),
                                                  ),
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            playlist.title,
                                            style: const TextStyle(
                                              color: AppTheme.primary,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            isLiked ? 'Playlist especial' : (playlist.description ?? 'Playlist'),
                                            style: const TextStyle(
                                              color: AppTheme.secondary,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
