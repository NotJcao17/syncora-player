import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/connectivity_service.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/playlist_cover_widget.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../../data/sync/sync_service.dart';
import '../import_export/playlist_import_export_service.dart';

/// Pantalla de Biblioteca conectada a Drift local, Supabase y servicio de Import/Export.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  String _selectedFilter = 'Playlists';
  final List<String> _filters = const ['Playlists', 'Álbumes'];

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(syncServiceProvider).syncLibrary(force: false);
    });
  }

  void _showCreatePlaylistDialog(BuildContext context, bool isConnected) {
    if (!isConnected) {
      AppToast.show(context, message: 'Sin conexión. No se pueden crear playlists offline.');
      return;
    }

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
                final description = descController.text.trim().isEmpty ? null : descController.text.trim();
                String? remoteId;
                try {
                  final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
                  final supabaseRes = await supabaseRepo.createPlaylist(title: title, description: description);
                  remoteId = supabaseRes['id']?.toString();
                } catch (_) {}

                final dao = ref.read(playlistDaoProvider);
                await dao.createPlaylist(
                  title: title,
                  description: description,
                  remoteId: remoteId,
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

  void _showPlaylistOptionsMenu(BuildContext context, Playlist playlist, bool isConnected) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceHover,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: Icon(AppIcons.broken(SolarIcons.PenNewSquare), color: isConnected ? AppTheme.primary : AppTheme.muted),
                title: Text('Editar nombre', style: TextStyle(color: isConnected ? AppTheme.primary : AppTheme.muted)),
                enabled: isConnected,
                onTap: () {
                  Navigator.pop(ctx);
                  _showEditPlaylistDialog(context, playlist);
                },
              ),
              ListTile(
                leading: Icon(
                  AppIcons.broken(playlist.isPublic ? SolarIcons.Lock : SolarIcons.Global),
                  color: isConnected ? AppTheme.primary : AppTheme.muted,
                ),
                title: Text(
                  playlist.isPublic ? 'Hacer privada' : 'Hacer pública',
                  style: TextStyle(color: isConnected ? AppTheme.primary : AppTheme.muted),
                ),
                enabled: isConnected,
                onTap: () async {
                  Navigator.pop(ctx);
                  final newPublic = !playlist.isPublic;
                  final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
                  final dao = ref.read(playlistDaoProvider);
                  String? remoteId = playlist.remoteId;
                  if (remoteId == null) {
                    try {
                      final supabaseRes = await supabaseRepo.createPlaylist(
                        title: playlist.title,
                        description: playlist.description,
                        isPublic: newPublic,
                        isLiked: playlist.isLiked,
                      );
                      remoteId = supabaseRes['id']?.toString();
                    } catch (_) {}
                  } else {
                    try {
                      await supabaseRepo.updatePlaylist(remoteId, isPublic: newPublic);
                    } catch (_) {}
                  }
                  await dao.updatePlaylist(playlist.copyWith(
                    isPublic: newPublic,
                    remoteId: Value(remoteId),
                  ));
                  if (context.mounted) {
                    AppToast.show(
                      context,
                      message: newPublic ? 'Playlist marcada como pública' : 'Playlist marcada como privada',
                    );
                  }
                },
              ),
              ListTile(
                leading: Icon(AppIcons.broken(SolarIcons.LinkMinimalistic), color: AppTheme.primary),
                title: const Text('Copiar enlace', style: TextStyle(color: AppTheme.primary)),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: 'syncoraplayer://playlist/${playlist.remoteId ?? playlist.id}'));
                  AppToast.show(context, message: 'Enlace copiado al portapapeles');
                },
              ),
              ListTile(
                leading: Icon(AppIcons.broken(SolarIcons.TrashBinMinimalistic), color: isConnected ? Colors.redAccent : AppTheme.muted),
                title: Text('Eliminar playlist', style: TextStyle(color: isConnected ? Colors.redAccent : AppTheme.muted)),
                enabled: isConnected,
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
                    if (playlist.remoteId != null) {
                      await supabaseRepo.deletePlaylist(playlist.remoteId!);
                    }
                  } catch (_) {}
                  final dao = ref.read(playlistDaoProvider);
                  await dao.deletePlaylist(playlist.id);
                  if (context.mounted) {
                    AppToast.show(context, message: 'Playlist eliminada');
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showEditPlaylistDialog(BuildContext context, Playlist playlist) {
    final titleController = TextEditingController(text: playlist.title);
    final descController = TextEditingController(text: playlist.description ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Editar Playlist', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
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
                labelText: 'Descripción',
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
              final newTitle = titleController.text.trim();
              if (newTitle.isNotEmpty) {
                final newDesc = descController.text.trim().isEmpty ? null : descController.text.trim();
                String? remoteId = playlist.remoteId;
                try {
                  final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
                  if (remoteId == null) {
                    final supabaseRes = await supabaseRepo.createPlaylist(
                      title: newTitle,
                      description: newDesc,
                      isPublic: playlist.isPublic,
                      isLiked: playlist.isLiked,
                    );
                    remoteId = supabaseRes['id']?.toString();
                  } else {
                    await supabaseRepo.updatePlaylist(remoteId, title: newTitle, description: newDesc);
                  }
                } catch (_) {}
                final dao = ref.read(playlistDaoProvider);
                await dao.updatePlaylist(playlist.copyWith(
                  title: newTitle,
                  description: Value(newDesc),
                  remoteId: Value(remoteId),
                ));
                if (ctx.mounted) Navigator.of(ctx).pop();
              }
            },
            child: const Text('Guardar', style: TextStyle(fontWeight: FontWeight.bold)),
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
        AppToast.show(context, message: 'No se encontraron canciones válidas en el archivo.');
      }
      return;
    }

    final dao = ref.read(playlistDaoProvider);
    final playlistName = file.name.replaceAll(RegExp(r'\.(csv|txt)$'), '');
    final playlistId = await dao.createPlaylist(
      title: 'Importada: $playlistName',
      description: 'Importada desde ${file.name}',
    );

    if (!context.mounted) return;

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
                        Icon(AppIcons.broken(SolarIcons.CheckCircle), color: Colors.green, size: 48),
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
    final isConnected = ref.watch(isConnectedProvider).value ?? true;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                    if (isDesktop)
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        color: AppTheme.primary,
                        onPressed: () async {
                          await ref.read(syncServiceProvider).syncLibrary(force: true);
                          await ref.read(syncServiceProvider).syncSavedAlbums(force: true);
                        },
                        tooltip: 'Sincronizar biblioteca',
                      ),
                    Tooltip(
                      message: 'Importar desde CSV/TXT',
                      child: IconButton(
                        icon: Icon(AppIcons.broken(SolarIcons.Import), color: AppTheme.primary, size: 20),
                        onPressed: () => _importPlaylistFromFile(context),
                      ),
                    ),
                    Tooltip(
                      message: 'Buscar',
                      child: IconButton(
                        icon: Icon(AppIcons.broken(SolarIcons.Magnifer), color: AppTheme.primary, size: 20),
                        onPressed: () => context.push('/search'),
                      ),
                    ),
                    Tooltip(
                      message: isConnected ? 'Crear playlist' : 'Sin conexión',
                      child: IconButton(
                        icon: Icon(
                          AppIcons.broken(SolarIcons.AddCircle),
                          color: isConnected ? AppTheme.primary : AppTheme.muted,
                          size: 22,
                        ),
                        onPressed: () => _showCreatePlaylistDialog(context, isConnected),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const Divider(color: AppTheme.surface, height: 1),
          const SizedBox(height: 12),

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

          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                await ref.read(syncServiceProvider).syncLibrary(force: true);
                await ref.read(syncServiceProvider).syncSavedAlbums(force: true);
              },
              child: _selectedFilter == 'Álbumes'
                  ? StreamBuilder<List<SavedAlbum>>(
                      stream: savedAlbumDao.watchAllSavedAlbums(),
                      builder: (ctx, snapshot) {
                        final albums = snapshot.data ?? [];
                        if (albums.isEmpty) {
                          return SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            child: Container(
                              height: MediaQuery.of(context).size.height * 0.5,
                              alignment: Alignment.center,
                              child: const Text(
                                'No tienes álbumes guardados',
                                style: TextStyle(color: AppTheme.secondary),
                              ),
                            ),
                          );
                        }

                        return ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
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
                        if (playlists.isEmpty) {
                          return SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            child: Container(
                              height: MediaQuery.of(context).size.height * 0.5,
                              alignment: Alignment.center,
                              child: const Text(
                                'No tienes playlists',
                                style: TextStyle(color: AppTheme.secondary),
                              ),
                            ),
                          );
                        }

                        return ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
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
                                      PlaylistCoverWidget(
                                        coverUrl: playlist.coverUrl,
                                        playlistId: playlist.id,
                                        isLiked: isLiked,
                                        width: 64,
                                        height: 64,
                                        borderRadius: BorderRadius.circular(12),
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
                                      if (!isLiked)
                                        IconButton(
                                          icon: Icon(AppIcons.broken(SolarIcons.MenuDots), color: AppTheme.secondary, size: 20),
                                          onPressed: () => _showPlaylistOptionsMenu(context, playlist, isConnected),
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
          ),
        ],
      ),
    );
  }
}
