import 'dart:io';
import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/connectivity_service.dart';
import '../../../core/utils/contributor_resolver.dart';
import '../../../core/utils/share_link_builder.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/playlist_cover_widget.dart';
import '../../../core/widgets/track_tile.dart';
import '../../../data/apis/deezer_api.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../../data/models/deezer/deezer_track.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../../data/sync/sync_service.dart';
import '../../auth/local_mode_provider.dart';
import '../../download/widgets/download_header_button.dart';
import '../../player/audio_engine/audio_engine_factory.dart';
import '../../player/audio_engine/audio_engine_state.dart';
import '../../player/player_models.dart';
import '../../player/player_providers.dart';
import '../../player/radio/radio_service.dart';
import '../../search/search_ranking.dart';
import '../ai_playlist/ai_modify_playlist_sheet.dart';
import '../import_export/playlist_import_export_service.dart';

enum PlaylistSortColumn { original, title, album, date, duration }
enum PlaylistSortDirection { asc, desc, none }

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

  // Ordenamiento de canciones en playlist
  PlaylistSortColumn _sortColumn = PlaylistSortColumn.original;
  PlaylistSortDirection _sortDirection = PlaylistSortDirection.none;

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

  Color _resolveDominantColor(Playlist playlist, List<SyncoraTrack> tracks) {
    if (playlist.isLiked) {
      return AppTheme.gradientLiked.colors.first;
    }
    final coverUrl = (playlist.coverUrl != null && playlist.coverUrl!.isNotEmpty)
        ? playlist.coverUrl!
        : (tracks.isNotEmpty ? tracks.first.coverUrl : '');

    if (coverUrl.startsWith('gradient:')) {
      final indexStr = coverUrl.replaceFirst('gradient:', '');
      final index = int.tryParse(indexStr) ?? 0;
      if (PlaylistCoverWidget.presetGradients.isNotEmpty) {
        return PlaylistCoverWidget.presetGradients[index % PlaylistCoverWidget.presetGradients.length].colors.first;
      }
    }

    if (coverUrl.startsWith('color:')) {
      final hex = coverUrl.replaceFirst('color:', '').replaceAll('#', '');
      final colorInt = int.tryParse(hex, radix: 16);
      if (colorInt != null) {
        return Color(hex.length == 6 ? 0xFF000000 | colorInt : colorInt);
      }
    }

    return _dominantColor ?? AppTheme.surfaceHover.withValues(alpha: 0.3);
  }

  void _extractPalette(String coverUrl) async {
    if (coverUrl.isEmpty || coverUrl.startsWith('gradient:') || coverUrl.startsWith('color:')) return;
    if (_extractedCoverUrl == coverUrl) return;
    _extractedCoverUrl = coverUrl;

    try {
      PaletteGenerator palette;
      if (coverUrl.startsWith('file://') || coverUrl.startsWith('/')) {
        final file = File(coverUrl.replaceFirst('file://', ''));
        if (!await file.exists()) return;
        palette = await PaletteGenerator.fromImageProvider(
          FileImage(file),
          maximumColorCount: 8,
        );
      } else {
        palette = await PaletteGenerator.fromImageProvider(
          NetworkImage(coverUrl),
          maximumColorCount: 8,
        );
      }
      final color = palette.darkVibrantColor?.color ?? palette.dominantColor?.color;
      if (mounted && color != null && _dominantColor != color) {
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

  void _showExportDialog(BuildContext context, List<PlaylistTrack> tracks) {
    if (_playlist == null || tracks.isEmpty) {
      AppToast.show(context, message: 'No hay canciones para exportar.');
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(AppIcons.broken(SolarIcons.Export), color: AppTheme.primary, size: 24),
            const SizedBox(width: 10),
            const Text('Exportar playlist', style: TextStyle(color: AppTheme.primary, fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text(
                  'Transfiere tu playlist a Spotify, Apple Music o Deezer:',
                  style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 14),
                ),
                SizedBox(height: 10),
                Text(
                  '1. Presiona el botón "Exportar a CSV" aquí abajo para guardar el archivo de la playlist.\n'
                  '2. Ingresa en tu navegador a tunemymusic.com o soundiiz.com.\n'
                  '3. Elige la opción "Subir archivo / CSV" como origen de tu música.\n'
                  '4. Selecciona tu plataforma de destino (Spotify, Apple Music, Deezer, etc.).\n'
                  '5. ¡Tus canciones se transferirán automáticamente!',
                  style: TextStyle(color: AppTheme.secondary, fontSize: 13, height: 1.45),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: AppTheme.secondary)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: AppTheme.background,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            icon: Icon(AppIcons.broken(SolarIcons.DownloadMinimalistic), size: 18),
            label: const Text('Exportar a CSV', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () {
              Navigator.pop(ctx);
              _exportPlaylist(tracks);
            },
          ),
        ],
      ),
    );
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

  void _cycleColumnSort(PlaylistSortColumn column) {
    setState(() {
      if (_sortColumn != column) {
        _sortColumn = column;
        _sortDirection = PlaylistSortDirection.asc;
      } else if (_sortDirection == PlaylistSortDirection.asc) {
        _sortDirection = PlaylistSortDirection.desc;
      } else {
        _sortColumn = PlaylistSortColumn.original;
        _sortDirection = PlaylistSortDirection.none;
      }
    });
  }

  List<_TrackPair> _sortTrackPairs(List<_TrackPair> pairs) {
    if (_sortDirection == PlaylistSortDirection.none || _sortColumn == PlaylistSortColumn.original) {
      return pairs;
    }

    final sorted = List<_TrackPair>.from(pairs);
    sorted.sort((a, b) {
      int cmp = 0;
      switch (_sortColumn) {
        case PlaylistSortColumn.title:
          cmp = a.syncoraTrack.title.toLowerCase().compareTo(b.syncoraTrack.title.toLowerCase());
          break;
        case PlaylistSortColumn.album:
          cmp = (a.syncoraTrack.album ?? '').toLowerCase().compareTo((b.syncoraTrack.album ?? '').toLowerCase());
          break;
        case PlaylistSortColumn.date:
          cmp = a.playlistTrack.addedAt.compareTo(b.playlistTrack.addedAt);
          break;
        case PlaylistSortColumn.duration:
          final dA = a.syncoraTrack.duration ?? Duration.zero;
          final dB = b.syncoraTrack.duration ?? Duration.zero;
          cmp = dA.compareTo(dB);
          break;
        case PlaylistSortColumn.original:
          cmp = 0;
          break;
      }
      return _sortDirection == PlaylistSortDirection.asc ? cmp : -cmp;
    });

    return sorted;
  }

  void _showEditPlaylistDialog(BuildContext context, Playlist playlist) {
    final titleController = TextEditingController(text: playlist.title);
    final descController = TextEditingController(text: playlist.description ?? '');
    String? selectedCoverUrl = playlist.coverUrl;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          return AlertDialog(
            backgroundColor: AppTheme.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('Editar playlist', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: titleController,
                      style: const TextStyle(color: AppTheme.primary),
                      decoration: InputDecoration(
                        labelText: 'Nombre de la playlist',
                        labelStyle: const TextStyle(color: AppTheme.secondary),
                        filled: true,
                        fillColor: AppTheme.background,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: descController,
                      maxLines: 2,
                      style: const TextStyle(color: AppTheme.primary),
                      decoration: InputDecoration(
                        labelText: 'Descripción (opcional)',
                        labelStyle: const TextStyle(color: AppTheme.secondary),
                        filled: true,
                        fillColor: AppTheme.background,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('Personalizar portada', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 8),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceHover,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(AppIcons.broken(SolarIcons.Gallery), color: AppTheme.primary, size: 20),
                      ),
                      title: const Text('Cuadrícula 2x2 automática', style: TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w600)),
                      subtitle: const Text('Muestra las carátulas de las canciones', style: TextStyle(color: AppTheme.secondary, fontSize: 11)),
                      trailing: (selectedCoverUrl == null || selectedCoverUrl!.isEmpty)
                          ? Icon(AppIcons.bold(SolarIcons.CheckCircle), color: AppTheme.primary, size: 20)
                          : null,
                      onTap: () {
                        setDialogState(() {
                          selectedCoverUrl = null;
                        });
                      },
                    ),
                    const Divider(color: AppTheme.surfaceHover, height: 16),
                    const Text('Degradados predefinidos', style: TextStyle(color: AppTheme.secondary, fontSize: 12)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: List.generate(PlaylistCoverWidget.presetGradients.length, (idx) {
                        final tag = 'gradient:$idx';
                        final isSelected = selectedCoverUrl == tag;
                        return GestureDetector(
                          onTap: () {
                            setDialogState(() {
                              selectedCoverUrl = tag;
                            });
                          },
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              gradient: PlaylistCoverWidget.presetGradients[idx],
                              borderRadius: BorderRadius.circular(8),
                              border: isSelected ? Border.all(color: Colors.white, width: 2.5) : null,
                            ),
                            child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 12),
                    const Text('Colores sólidos', style: TextStyle(color: AppTheme.secondary, fontSize: 12)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: List.generate(PlaylistCoverWidget.presetColors.length, (idx) {
                        final color = PlaylistCoverWidget.presetColors[idx];
                        final hex = '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
                        final tag = 'color:$hex';
                        final isSelected = selectedCoverUrl == tag;
                        return GestureDetector(
                          onTap: () {
                            setDialogState(() {
                              selectedCoverUrl = tag;
                            });
                          },
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(8),
                              border: isSelected ? Border.all(color: Colors.white, width: 2.5) : null,
                            ),
                            child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                          ),
                        );
                      }),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar', style: TextStyle(color: AppTheme.secondary)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: AppTheme.background,
                ),
                onPressed: () async {
                  final newTitle = titleController.text.trim();
                  if (newTitle.isEmpty) return;
                  final newDesc = descController.text.trim();

                  final dao = ref.read(playlistDaoProvider);
                  await dao.updatePlaylist(playlist.copyWith(
                    title: newTitle,
                    description: Value(newDesc.isEmpty ? null : newDesc),
                    coverUrl: Value(selectedCoverUrl),
                  ));

                  if (playlist.remoteId != null) {
                    try {
                      final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
                      await supabaseRepo.updatePlaylist(
                        playlist.remoteId!,
                        title: newTitle,
                        description: newDesc.isEmpty ? null : newDesc,
                        coverUrl: selectedCoverUrl,
                      );
                    } catch (_) {}
                  }

                  if (ctx.mounted) Navigator.pop(ctx);
                  if (context.mounted) {
                    AppToast.show(context, message: 'Playlist actualizada');
                  }
                },
                child: const Text('Guardar cambios', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showAddAllToOtherPlaylistDialog(BuildContext context, List<PlaylistTrack> currentTracks) async {
    final dao = ref.read(playlistDaoProvider);
    final allPlaylists = await dao.getAllPlaylists();
    final otherPlaylists = allPlaylists.where((p) => p.id != _playlist?.id && !p.isLiked).toList();

    if (!context.mounted) return;

    if (otherPlaylists.isEmpty) {
      AppToast.show(context, message: 'No tienes otras playlists para copiar canciones.');
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Agregar todas a otra playlist', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: 320,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: otherPlaylists.length,
            itemBuilder: (c, i) {
              final target = otherPlaylists[i];
              return ListTile(
                leading: Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.primary),
                title: Text(target.title, style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
                subtitle: Text(target.description ?? 'Playlist', style: const TextStyle(color: AppTheme.secondary, fontSize: 12)),
                onTap: () async {
                  final targetTracks = await dao.getTracksOrdered(target.id);
                  final targetIds = targetTracks.map((t) => t.trackId).toSet();
                  final targetTitles = targetTracks.map((t) => '${t.title.toLowerCase()}_${t.artistName.toLowerCase()}').toSet();

                  final tracksToAdd = currentTracks.where((t) {
                    final isDupId = targetIds.contains(t.trackId);
                    final isDupTitle = targetTitles.contains('${t.title.toLowerCase()}_${t.artistName.toLowerCase()}');
                    return !isDupId && !isDupTitle;
                  }).toList();

                  final skipped = currentTracks.length - tracksToAdd.length;

                  if (tracksToAdd.isEmpty) {
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (context.mounted) {
                      AppToast.show(context, message: 'Todas las canciones ya estaban en "${target.title}".');
                    }
                    return;
                  }

                  final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
                  if (target.remoteId != null) {
                    try {
                      await supabaseRepo.addTracksToPlaylist(
                        target.remoteId!,
                        tracksToAdd
                            .map((t) => {
                                  'track_id': t.trackId,
                                  'artist_id': t.artistId,
                                  'album_id': t.albumId,
                                  'title': t.title,
                                  'artist_name': t.artistName,
                                  'album_name': t.albumName,
                                  'cover_url': t.coverUrl,
                                  'duration_ms': t.durationMs,
                                  if (t.genre != null) 'genre': t.genre,
                                  if (t.contributorsJson != null) 'contributors_json': t.contributorsJson,
                                })
                            .toList(),
                      );
                    } catch (_) {}
                  }

                  for (final t in tracksToAdd) {
                    await dao.addTrackToPlaylist(
                      playlistId: target.id,
                      trackId: t.trackId,
                      artistId: t.artistId,
                      albumId: t.albumId,
                      title: t.title,
                      artistName: t.artistName,
                      albumName: t.albumName,
                      coverUrl: t.coverUrl,
                      durationMs: t.durationMs,
                      contributorsJson: t.contributorsJson,
                    );
                  }

                  if (ctx.mounted) Navigator.pop(ctx);
                  if (context.mounted) {
                    AppToast.show(
                      context,
                      message: skipped > 0
                          ? 'Se agregaron ${tracksToAdd.length} canciones a "${target.title}" ($skipped duplicadas omitidas).'
                          : 'Se agregaron ${tracksToAdd.length} canciones a "${target.title}".',
                    );
                  }
                },
              );
            },
          ),
        ),
      ),
    );
  }

  void _deduplicatePlaylistTracks(Playlist playlist, List<PlaylistTrack> tracks) async {
    final seenIds = <int>{};
    final seenTitles = <String>{};
    final duplicateTrackDbIds = <int>[];
    final duplicateTrackIds = <int>[];

    for (final t in tracks) {
      final key = '${t.title.trim().toLowerCase()}_${t.artistName.trim().toLowerCase()}';
      if (seenIds.contains(t.trackId) || seenTitles.contains(key)) {
        duplicateTrackDbIds.add(t.id);
        duplicateTrackIds.add(t.trackId);
      } else {
        seenIds.add(t.trackId);
        seenTitles.add(key);
      }
    }

    if (duplicateTrackDbIds.isEmpty) {
      AppToast.show(context, message: 'No hay canciones repetidas en esta playlist.');
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('¿Eliminar canciones repetidas?', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold)),
        content: Text(
          'Se encontraron ${duplicateTrackDbIds.length} canciones duplicadas. ¿Deseas eliminarlas dejando solo una instancia de cada una?',
          style: const TextStyle(color: AppTheme.secondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: AppTheme.secondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar duplicados', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final dao = ref.read(playlistDaoProvider);
    final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);

    for (final dbId in duplicateTrackDbIds) {
      await dao.removeTrackEntry(dbId);
    }

    if (playlist.remoteId != null) {
      for (final trackId in duplicateTrackIds) {
        try {
          await supabaseRepo.removeTrackFromPlaylist(playlist.remoteId!, trackId);
        } catch (_) {}
      }
    }

    if (mounted) {
      AppToast.show(context, message: 'Se eliminaron ${duplicateTrackDbIds.length} canciones repetidas.');
    }
  }

  /// Mismo flujo que el menú de la biblioteca: si la playlist todavía no
  /// existe en Supabase hay que crearla ahí antes de poder marcarla pública,
  /// porque la visibilidad vive del lado del servidor (RLS).
  Future<void> _togglePublic(Playlist playlist) async {
    final newPublic = !playlist.isPublic;
    final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
    final dao = ref.read(playlistDaoProvider);
    String? remoteId = playlist.remoteId;
    if (remoteId == null) {
      try {
        final res = await supabaseRepo.createPlaylist(
          title: playlist.title,
          description: playlist.description,
          isPublic: newPublic,
          isLiked: playlist.isLiked,
        );
        remoteId = res['id']?.toString();
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
    if (!mounted) return;
    AppToast.show(
      context,
      message: newPublic ? 'Playlist marcada como pública' : 'Playlist marcada como privada',
    );
  }

  Widget _buildPlaylistOptionsContent(BuildContext ctx, Playlist playlist, List<PlaylistTrack> tracks) {
    final isLocalMode = ref.read(localModeProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!playlist.isLiked) ...[
          ListTile(
            leading: Icon(AppIcons.broken(SolarIcons.Pen), color: AppTheme.primary),
            title: const Text('Editar información y portada', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
            onTap: () {
              Navigator.pop(ctx);
              _showEditPlaylistDialog(context, playlist);
            },
          ),
          ListTile(
            leading: Icon(AppIcons.broken(SolarIcons.StarsMinimalistic), color: AppTheme.accent),
            title: const Text('Modificar con IA', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
            onTap: () {
              Navigator.pop(ctx);
              final isConnected = ref.read(isConnectedProvider).value ?? true;
              if (!isConnected) {
                AppToast.show(context, message: 'Sin conexión. Las funciones de inteligencia artificial requieren conexión a internet.');
                return;
              }
              showAiModifyPlaylistSheet(context, ref, playlist);
            },
          ),
        ],
        if (!isLocalMode) ...[
          ListTile(
            leading: Icon(
              AppIcons.broken(playlist.isPublic ? SolarIcons.Lock : SolarIcons.Global),
              color: AppTheme.primary,
            ),
            title: Text(
              playlist.isPublic ? 'Hacer privada' : 'Hacer pública',
              style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600),
            ),
            onTap: () async {
              Navigator.pop(ctx);
              await _togglePublic(playlist);
            },
          ),
          ListTile(
            leading: Icon(AppIcons.broken(SolarIcons.LinkMinimalistic), color: AppTheme.primary),
            title: const Text('Copiar enlace', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
            onTap: () {
              Navigator.pop(ctx);
              Clipboard.setData(ClipboardData(text: ShareLinkBuilder.playlist('${playlist.remoteId ?? playlist.id}')));
              AppToast.show(context, message: 'Enlace copiado. Se abre en Syncora en quien tenga la app');
            },
          ),
        ],
        if (tracks.isNotEmpty)
          ListTile(
            leading: Icon(AppIcons.broken(SolarIcons.AddFolder), color: AppTheme.primary),
            title: const Text('Agregar todas a otra playlist', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
            onTap: () {
              Navigator.pop(ctx);
              _showAddAllToOtherPlaylistDialog(context, tracks);
            },
          ),
        if (tracks.isNotEmpty)
          ListTile(
            leading: Icon(AppIcons.broken(SolarIcons.CheckSquare), color: AppTheme.primary),
            title: const Text('Eliminar canciones repetidas', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
            onTap: () {
              Navigator.pop(ctx);
              _deduplicatePlaylistTracks(playlist, tracks);
            },
          ),
        ListTile(
          leading: Icon(AppIcons.broken(SolarIcons.Export), color: AppTheme.primary),
          title: const Text('Exportar playlist (CSV)', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
          onTap: () {
            Navigator.pop(ctx);
            _showExportDialog(context, tracks);
          },
        ),
        if (!playlist.isLiked)
          ListTile(
            leading: Icon(AppIcons.broken(SolarIcons.TrashBinTrash), color: Colors.red),
            title: const Text('Eliminar playlist', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
            onTap: () async {
              Navigator.pop(ctx);
              final confirm = await showDialog<bool>(
                context: context,
                builder: (dCtx) => AlertDialog(
                  backgroundColor: AppTheme.surface,
                  title: const Text('¿Eliminar playlist?', style: TextStyle(color: AppTheme.primary)),
                  content: const Text('Esta acción no se puede deshacer.', style: TextStyle(color: AppTheme.secondary)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Cancelar')),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: () => Navigator.pop(dCtx, true),
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
                  await ref.read(playlistDaoProvider).deletePlaylist(playlist.id);
                }
                if (mounted && context.canPop()) context.pop();
              }
            },
          ),
      ],
    );
  }

  void _showPlaylistOptionsMenu(BuildContext context, Playlist playlist, List<PlaylistTrack> tracks) {
    final isDesktop = MediaQuery.of(context).size.width >= 768;
    if (isDesktop) {
      showDialog(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: AppTheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF2A2A2A)),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: _buildPlaylistOptionsContent(ctx, playlist, tracks),
            ),
          ),
        ),
      );
    } else {
      showModalBottomSheet(
        context: context,
        backgroundColor: AppTheme.surface,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: _buildPlaylistOptionsContent(ctx, playlist, tracks),
          ),
        ),
      );
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

        return Scaffold(
          backgroundColor: AppTheme.background,
          body: StreamBuilder<List<PlaylistTrack>>(
            stream: playlistDao.watchTracksOrdered(playlist.id),
            builder: (ctx, snapshot) {
              final tracks = snapshot.data ?? [];
              final rawPairs = tracks.map((t) {
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

                final syncora = SyncoraTrack(
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
                return _TrackPair(playlistTrack: t, syncoraTrack: syncora);
              }).toList();

              final sortedPairs = _sortTrackPairs(rawPairs);
              final sortedSyncoraTracks = sortedPairs.map((p) => p.syncoraTrack).toList();

              final rawSyncoraTracks = rawPairs.map((p) => p.syncoraTrack).toList();

              final coverForPalette = (playlist.coverUrl != null && playlist.coverUrl!.isNotEmpty)
                  ? playlist.coverUrl!
                  : (rawSyncoraTracks.isNotEmpty ? rawSyncoraTracks.first.coverUrl : '');
              if (!playlist.isLiked && coverForPalette.isNotEmpty) {
                _extractPalette(coverForPalette);
              }
              final dominantGradientColor = _resolveDominantColor(playlist, rawSyncoraTracks).withValues(alpha: 0.35);

              final playlistContextId = 'playlist_${playlist.id}';
              final isCurrentContext = ref.watch(playerStateProvider.select((s) => s.activeContextId == playlistContextId));
              final isBuffering = ref.watch(playerStateProvider.select((s) =>
                  s.engine.processingState == AudioProcessingState.loading ||
                  s.engine.processingState == AudioProcessingState.buffering));
              final showPauseHeader = isCurrentContext && (isPlaying || isBuffering);

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
                        child: CustomScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          slivers: [
                            SliverPadding(
                              padding: EdgeInsets.only(
                                top: MediaQuery.of(context).padding.top + 56,
                                left: isDesktop ? 32 : 12,
                                right: isDesktop ? 32 : 12,
                              ),
                              sliver: SliverToBoxAdapter(
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
                                              tracks: rawSyncoraTracks,
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
                                                tracks: rawSyncoraTracks,
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

                                    // Fila de acciones principales
                                    SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: Row(
                                        mainAxisAlignment: isDesktop ? MainAxisAlignment.start : MainAxisAlignment.center,
                                        children: [
                                          if (sortedSyncoraTracks.isNotEmpty) ...[
                                            _HeaderPlayButton(
                                              isPlaying: showPauseHeader,
                                              isLoading: isCurrentContext && isBuffering,
                                              onPressed: () {
                                                if (showPauseHeader) {
                                                  controller.pause();
                                                } else if (isCurrentContext) {
                                                  controller.play();
                                                } else {
                                                  final isShuffle = ref.read(playerStateProvider).isShuffle;
                                                  final startIndex = isShuffle
                                                      ? RadioService.pickShuffledStartIndex(sortedSyncoraTracks.length, math.Random())
                                                      : 0;
                                                  controller.setQueue(sortedSyncoraTracks, startIndex: startIndex, activeContextId: playlistContextId);
                                                  controller.play();
                                                }
                                              },
                                            ),
                                            const SizedBox(width: 8),
                                            DownloadHeaderButton(
                                              title: playlist.title,
                                              tracks: sortedSyncoraTracks,
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

                                          if (isDesktop) ...[
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

                                            if (!playlist.isLiked) ...[
                                              ElevatedButton.icon(
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor: AppTheme.surface,
                                                  foregroundColor: AppTheme.accent,
                                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                                ),
                                                onPressed: () {
                                                  final isConnected = ref.read(isConnectedProvider).value ?? true;
                                                  if (!isConnected) {
                                                    AppToast.show(context, message: 'Sin conexión. Las funciones de inteligencia artificial requieren conexión a internet.');
                                                    return;
                                                  }
                                                  showAiModifyPlaylistSheet(context, ref, playlist);
                                                },
                                                icon: Icon(AppIcons.broken(SolarIcons.StarsMinimalistic), size: 18),
                                                label: const Text('Modificar con IA', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                              ),
                                              const SizedBox(width: 8),
                                            ],
                                          ] else ...[
                                            Tooltip(
                                              message: _showAddSongsSearch ? 'Cerrar buscador' : 'Agregar canciones',
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  color: _showAddSongsSearch ? AppTheme.surfaceHover : AppTheme.surface,
                                                  shape: BoxShape.circle,
                                                ),
                                                child: IconButton(
                                                  icon: Icon(_showAddSongsSearch ? AppIcons.broken(SolarIcons.CloseCircle) : AppIcons.broken(SolarIcons.AddCircle), color: AppTheme.primary, size: 20),
                                                  onPressed: () {
                                                    setState(() => _showAddSongsSearch = !_showAddSongsSearch);
                                                  },
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),

                                            if (!playlist.isLiked) ...[
                                              Tooltip(
                                                message: 'Modificar con IA',
                                                child: Container(
                                                  decoration: const BoxDecoration(
                                                    color: AppTheme.surface,
                                                    shape: BoxShape.circle,
                                                  ),
                                                  child: IconButton(
                                                    icon: Icon(AppIcons.broken(SolarIcons.StarsMinimalistic), color: AppTheme.accent, size: 20),
                                                    onPressed: () {
                                                      final isConnected = ref.read(isConnectedProvider).value ?? true;
                                                      if (!isConnected) {
                                                        AppToast.show(context, message: 'Sin conexión. Las funciones de inteligencia artificial requieren conexión a internet.');
                                                        return;
                                                      }
                                                      showAiModifyPlaylistSheet(context, ref, playlist);
                                                    },
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                            ],
                                          ],

                                          // Ordenamiento en Móvil
                                          if (!isDesktop && sortedSyncoraTracks.isNotEmpty) ...[
                                            PopupMenuButton<PlaylistSortColumn>(
                                              icon: Icon(AppIcons.broken(SolarIcons.SortVertical), color: AppTheme.secondary, size: 22),
                                              tooltip: 'Ordenar canciones',
                                              color: const Color(0xFF1E1E1E),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFF2A2A2A))),
                                              onSelected: (col) => _cycleColumnSort(col),
                                              itemBuilder: (c) => [
                                                const PopupMenuItem(value: PlaylistSortColumn.original, child: Text('Orden original', style: TextStyle(color: AppTheme.primary, fontSize: 13))),
                                                const PopupMenuItem(value: PlaylistSortColumn.title, child: Text('Título', style: TextStyle(color: AppTheme.primary, fontSize: 13))),
                                                const PopupMenuItem(value: PlaylistSortColumn.album, child: Text('Álbum', style: TextStyle(color: AppTheme.primary, fontSize: 13))),
                                                const PopupMenuItem(value: PlaylistSortColumn.duration, child: Text('Duración', style: TextStyle(color: AppTheme.primary, fontSize: 13))),
                                              ],
                                            ),
                                            const SizedBox(width: 8),
                                          ],

                                          // Menú de 3 puntos de la Playlist
                                          IconButton(
                                            icon: Icon(AppIcons.broken(SolarIcons.MenuDots), color: AppTheme.secondary, size: 22),
                                            onPressed: () => _showPlaylistOptionsMenu(context, playlist, tracks),
                                            tooltip: 'Opciones de playlist',
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
                                              onChanged: (val) {
                                                if (!_showAddSongsSearch) {
                                                  setState(() => _showAddSongsSearch = true);
                                                }
                                                _performAddSongsSearch(val);
                                              },
                                              style: const TextStyle(color: AppTheme.primary),
                                              decoration: InputDecoration(
                                                hintText: 'Escribe el nombre de la canción',
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
                                                  final existingEntries = tracks.where((t) => t.trackId == track.id).toList();
                                                  final isAlreadyAdded = existingEntries.isNotEmpty;
                                                  return ListTile(
                                                    contentPadding: EdgeInsets.zero,
                                                    leading: ClipRRect(
                                                      borderRadius: BorderRadius.circular(6),
                                                      child: CachedNetworkImage(imageUrl: track.coverUrl, width: 40, height: 40, fit: BoxFit.cover),
                                                    ),
                                                    title: Text(track.title, style: const TextStyle(color: AppTheme.primary, fontSize: 14, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                                                    subtitle: Text(track.artistName, style: const TextStyle(color: AppTheme.secondary, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                                                    trailing: SizedBox(
                                                      width: 48,
                                                      height: 48,
                                                      child: Center(
                                                        child: isAlreadyAdded
                                                            ? IconButton(
                                                                icon: const Icon(Icons.check_circle, color: Colors.white, size: 22),
                                                                tooltip: 'Quitar de la playlist',
                                                                onPressed: () async {
                                                                  final ok = await _executeRemoteMutation(() async {
                                                                    if (playlist.remoteId != null) {
                                                                      final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
                                                                      await supabaseRepo.removeTrackFromPlaylist(playlist.remoteId!, track.id);
                                                                    }
                                                                  });
                                                                  if (!ok) return;
                                                                  for (final entry in existingEntries) {
                                                                    await playlistDao.removeTrackEntry(entry.id);
                                                                  }
                                                                  if (!context.mounted) return;
                                                                  AppToast.show(context, message: '"${track.title}" quitada de la playlist');
                                                                },
                                                              )
                                                            : IconButton(
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
                                                      ),
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
                                  ],
                                ),
                              ),
                            ),

                            if (tracks.isEmpty && !_showAddSongsSearch)
                              const SliverToBoxAdapter(
                                child: Padding(
                                  padding: EdgeInsets.symmetric(vertical: 20),
                                  child: Center(
                                    child: Text(
                                      'Esta playlist está vacía.\nUsa el buscador de arriba para agregar canciones.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(color: AppTheme.secondary, height: 1.5),
                                    ),
                                  ),
                                ),
                              )
                            else ...[
                              if (isDesktop && sortedSyncoraTracks.isNotEmpty)
                                SliverPadding(
                                  padding: const EdgeInsets.symmetric(horizontal: 32),
                                  sliver: SliverToBoxAdapter(
                                    child: Column(
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          child: Row(
                                            children: [
                                              _buildDesktopColumnHeader(
                                                label: '#',
                                                column: PlaylistSortColumn.original,
                                                width: 48,
                                                alignment: Alignment.center,
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                flex: 3,
                                                child: Padding(
                                                  padding: const EdgeInsets.only(left: 60),
                                                  child: _buildDesktopColumnHeader(
                                                    label: 'TÍTULO',
                                                    column: PlaylistSortColumn.title,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 16),
                                              Expanded(
                                                flex: 2,
                                                child: _buildDesktopColumnHeader(
                                                  label: 'ÁLBUM',
                                                  column: PlaylistSortColumn.album,
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              _buildDesktopColumnHeader(
                                                label: '',
                                                icon: AppIcons.broken(SolarIcons.ClockCircle),
                                                column: PlaylistSortColumn.duration,
                                                width: 50,
                                                alignment: Alignment.centerRight,
                                              ),
                                              const SizedBox(width: 52),
                                            ],
                                          ),
                                        ),
                                        const Divider(height: 12, color: AppTheme.surfaceHover),
                                      ],
                                    ),
                                  ),
                                ),
                              SliverPadding(
                                padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 12),
                                sliver: SliverList.builder(
                                  itemCount: sortedPairs.length,
                                  itemBuilder: (ctx, i) {
                                    final pair = sortedPairs[i];
                                    final track = pair.syncoraTrack;
                                    final playlistTrack = pair.playlistTrack;
                                    final isPlayingTrack = currentTrack?.id == track.id;

                                    return TrackTile(
                                      track: track,
                                      index: i,
                                      isPlaying: isPlayingTrack,
                                      showAlbum: true,
                                      onTap: () {
                                        controller.setQueue(sortedSyncoraTracks, startIndex: i, activeContextId: playlistContextId);
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
                              ),
                            ],

                            // Sección de recomendaciones Deezer al pie de la playlist
                            SliverPadding(
                              padding: EdgeInsets.symmetric(
                                horizontal: isDesktop ? 32 : 12,
                                vertical: 24,
                              ),
                              sliver: SliverToBoxAdapter(
                                child: _DeezerRecommendationsSection(
                                  playlist: playlist,
                                  existingTracks: tracks,
                                  onTrackAdded: () => setState(() {}),
                                ),
                              ),
                            ),

                            const SliverToBoxAdapter(
                              child: SizedBox(height: 40),
                            ),
                          ],
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

  Widget _buildDesktopColumnHeader({
    required String label,
    required PlaylistSortColumn column,
    IconData? icon,
    double? width,
    Alignment alignment = Alignment.centerLeft,
  }) {
    final isSorted = _sortColumn == column && _sortDirection != PlaylistSortDirection.none;
    final sortIcon = _sortDirection == PlaylistSortDirection.asc
        ? AppIcons.broken(SolarIcons.AltArrowUp)
        : AppIcons.broken(SolarIcons.AltArrowDown);

    Widget child = InkWell(
      onTap: () => _cycleColumnSort(column),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null)
              Icon(icon, color: isSorted ? AppTheme.primary : AppTheme.secondary, size: 16)
            else
              Text(
                label,
                style: TextStyle(
                  color: isSorted ? AppTheme.primary : AppTheme.secondary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            if (isSorted) ...[
              const SizedBox(width: 4),
              Icon(sortIcon, color: AppTheme.primary, size: 14),
            ],
          ],
        ),
      ),
    );

    if (width != null) {
      return SizedBox(
        width: width,
        child: Align(
          alignment: alignment,
          child: child,
        ),
      );
    }

    return Align(
      alignment: alignment,
      child: child,
    );
  }
}

class _TrackPair {
  final PlaylistTrack playlistTrack;
  final SyncoraTrack syncoraTrack;

  _TrackPair({required this.playlistTrack, required this.syncoraTrack});
}

class _HeaderPlayButton extends StatefulWidget {
  final bool isPlaying;
  final bool isLoading;
  final VoidCallback onPressed;

  const _HeaderPlayButton({
    required this.isPlaying,
    this.isLoading = false,
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
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
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
            child: Center(
              child: widget.isLoading
                  ? LoadingAnimationWidget.threeArchedCircle(
                      color: AppTheme.background,
                      size: 26,
                    )
                  : Icon(
                      widget.isPlaying ? AppIcons.broken(SolarIcons.Pause) : AppIcons.outline(SolarIcons.Play),
                      color: AppTheme.background,
                      size: 28,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Recomendaciones de Deezer para una playlist, cacheadas por id de playlist
/// (`FutureProvider.family`) para no recalcularlas en cada rebuild/rotación
/// -- solo se recalculan cuando cambia el id de playlist o se invalida
/// manualmente (botón "Actualizar"). Reusa el mismo algoritmo de radio/cola
/// infinita que `syncoraPlayerControllerProvider` (`RadioService.generateBatch`,
/// muestreo ponderado por artista) en vez de una heurística propia.
final playlistRecommendationsProvider = FutureProvider.family<List<SyncoraTrack>, int>((ref, playlistId) async {
  final dao = ref.read(playlistDaoProvider);
  final deezerApi = ref.read(deezerApiProvider);
  final tracks = await dao.getTracksOrdered(playlistId);

  final contextTracks = tracks
      .map((t) => SyncoraTrack(
            id: t.trackId.toString(),
            title: t.title,
            artist: t.artistName,
            artistId: t.artistId,
            album: t.albumName,
            albumId: t.albumId,
            duration: Duration(milliseconds: t.durationMs),
            artUri: t.coverUrl.isNotEmpty ? Uri.tryParse(t.coverUrl) : null,
          ))
      .toList();

  final excludeIds = tracks.map((t) => t.trackId.toString()).toSet();
  final radioService = RadioService(deezerApi: deezerApi);
  final results = await radioService.generateBatch(contextTracks: contextTracks, excludeIds: excludeIds);
  return results.take(10).toList();
});

/// Sección de recomendaciones Deezer al pie de la Playlist con preview player de 30s.
class _DeezerRecommendationsSection extends ConsumerStatefulWidget {
  final Playlist playlist;
  final List<PlaylistTrack> existingTracks;
  final VoidCallback onTrackAdded;

  const _DeezerRecommendationsSection({
    required this.playlist,
    required this.existingTracks,
    required this.onTrackAdded,
  });

  @override
  ConsumerState<_DeezerRecommendationsSection> createState() => _DeezerRecommendationsSectionState();
}

class _DeezerRecommendationsSectionState extends ConsumerState<_DeezerRecommendationsSection> {
  AudioEngine? _previewEngine;
  String? _activePreviewTrackId;
  bool _isPreviewPlaying = false;
  final Set<String> _addedTrackIds = {};

  // Ids ya mostrados en esta visita a la playlist (el lote inicial del
  // `FutureProvider` más cada "Actualizar" manual) -- se agregan al
  // exclude-list de la siguiente generación para que "Actualizar" no pueda
  // repetir exactamente el mismo lote. Vive en el estado local (no en el
  // provider) para que se olvide solo al salir de la pantalla, como pide el
  // ítem 16: "no need infinite variety forever, solo no repetir dentro de la
  // misma visita".
  final Set<String> _shownTrackIds = {};
  List<SyncoraTrack>? _manualRecommendations;
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    _previewEngine = createAudioEngine();
    _previewEngine?.completionStream.listen((_) {
      if (mounted) {
        setState(() {
          _isPreviewPlaying = false;
          _activePreviewTrackId = null;
        });
      }
    });
  }

  Future<void> _refreshRecommendations() async {
    setState(() => _isRefreshing = true);
    try {
      final dao = ref.read(playlistDaoProvider);
      final deezerApi = ref.read(deezerApiProvider);
      final tracks = await dao.getTracksOrdered(widget.playlist.id);

      final contextTracks = tracks
          .map((t) => SyncoraTrack(
                id: t.trackId.toString(),
                title: t.title,
                artist: t.artistName,
                artistId: t.artistId,
                album: t.albumName,
                albumId: t.albumId,
                duration: Duration(milliseconds: t.durationMs),
                artUri: t.coverUrl.isNotEmpty ? Uri.tryParse(t.coverUrl) : null,
              ))
          .toList();

      // Excluye las canciones ya en la playlist Y todo lo ya mostrado en
      // refrescos anteriores de esta visita -- sin lo segundo, un muestreo
      // ponderado que vuelve a elegir a los mismos artistas semilla (muy
      // probable si 1-2 artistas dominan el contexto) devolvía el mismo lote
      // cacheado por `DeezerApi` para ese artista.
      final excludeIds = {
        ...tracks.map((t) => t.trackId.toString()),
        ..._shownTrackIds,
      };
      final radioService = RadioService(deezerApi: deezerApi);
      final results = await radioService.generateBatch(contextTracks: contextTracks, excludeIds: excludeIds);
      final batch = results.take(10).toList();

      if (!mounted) return;
      setState(() {
        _manualRecommendations = batch;
        _shownTrackIds.addAll(batch.map((t) => t.id));
        _addedTrackIds.clear();
        _isRefreshing = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  @override
  void dispose() {
    _previewEngine?.stop();
    _previewEngine?.dispose();
    super.dispose();
  }

  /// Filtra las pistas ya presentes en la playlist (por si se agregaron por
  /// otra vía -- buscador inline, etc. -- después de resolver el lote
  /// cacheado) y las recién agregadas desde esta misma sección.
  List<SyncoraTrack> _visibleRecommendations(List<SyncoraTrack> cached) {
    final existingIds = widget.existingTracks.map((t) => t.trackId.toString()).toSet();
    return cached.where((t) => !existingIds.contains(t.id) && !_addedTrackIds.contains(t.id)).toList();
  }

  Future<void> _togglePreview(SyncoraTrack track) async {
    if (track.previewUrl == null || track.previewUrl!.isEmpty) {
      AppToast.show(context, message: 'Previsualización de audio no disponible para esta canción.');
      return;
    }

    if (_activePreviewTrackId == track.id && _isPreviewPlaying) {
      await _previewEngine?.pause();
      if (mounted) setState(() => _isPreviewPlaying = false);
      return;
    }

    if (_activePreviewTrackId == track.id && !_isPreviewPlaying) {
      ref.read(syncoraPlayerControllerProvider.notifier).pause();
      await _previewEngine?.play();
      if (mounted) setState(() => _isPreviewPlaying = true);
      return;
    }

    // Pausar reproductor principal
    ref.read(syncoraPlayerControllerProvider.notifier).pause();

    try {
      final vol = ref.read(playerStateProvider).engine.volume;
      await _previewEngine?.stop();
      await _previewEngine?.setVolume(vol);
      await _previewEngine?.setUrl(track.previewUrl!);
      await _previewEngine?.play();

      if (mounted) {
        setState(() {
          _activePreviewTrackId = track.id;
          _isPreviewPlaying = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _activePreviewTrackId = null;
          _isPreviewPlaying = false;
        });
      }
    }
  }

  Future<void> _addRecommendedTrack(SyncoraTrack track) async {
    final dao = ref.read(playlistDaoProvider);
    final supabaseRepo = ref.read(supabasePlaylistRepositoryProvider);
    final durationMs = track.duration?.inMilliseconds ?? 0;

    if (widget.playlist.remoteId != null) {
      try {
        await supabaseRepo.addTrackToPlaylist(widget.playlist.remoteId!, {
          'track_id': track.deezerId,
          'artist_id': track.artistId,
          'album_id': track.albumId,
          'title': track.title,
          'artist_name': track.artist,
          'album_name': track.album,
          'cover_url': track.coverUrl,
          'duration_ms': durationMs,
        });
      } catch (_) {}
    }

    final contributors = await resolveTrackContributors(ref.read(deezerApiProvider), track);

    await dao.addTrackToPlaylist(
      playlistId: widget.playlist.id,
      trackId: track.deezerId,
      artistId: track.artistId ?? 0,
      albumId: track.albumId ?? 0,
      title: track.title,
      artistName: track.artist,
      albumName: track.album ?? '',
      coverUrl: track.coverUrl,
      durationMs: durationMs,
      contributorsJson: SyncoraArtistRef.encodeList(contributors),
    );

    if (mounted) {
      if (_activePreviewTrackId == track.id) {
        _previewEngine?.stop();
        _isPreviewPlaying = false;
        _activePreviewTrackId = null;
      }
      setState(() {
        _addedTrackIds.add(track.id);
      });
      AppToast.show(context, message: '"${track.title}" agregada a la playlist');
      widget.onTrackAdded();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(isPlayingProvider, (previous, next) {
      if (next && _isPreviewPlaying) {
        _previewEngine?.pause();
        if (mounted) {
          setState(() {
            _isPreviewPlaying = false;
          });
        }
      }
    });

    final recommendationsAsync = ref.watch(playlistRecommendationsProvider(widget.playlist.id));
    ref.listen<AsyncValue<List<SyncoraTrack>>>(playlistRecommendationsProvider(widget.playlist.id), (previous, next) {
      // Semilla el exclude-list de "Actualizar" con el lote inicial del
      // provider, para que el primer refresco manual tampoco pueda repetirlo
      // -- solo mientras no haya habido ya un refresco manual (si lo hubo,
      // `_manualRecommendations` manda y este provider ya no vuelve a
      // resolver salvo invalidación externa).
      final data = next.value;
      if (data != null && _manualRecommendations == null) {
        _shownTrackIds.addAll(data.map((t) => t.id));
      }
    });

    // El spinner grande solo reemplaza toda la sección en la carga inicial
    // -- durante un refresco manual se mantiene visible el lote anterior
    // (con el spinner chico del botón "Actualizar" como único indicador),
    // porque colapsar la lista entera a un spinner centrado y volver a
    // expandirla es lo que producía el salto de scroll hacia arriba
    // reportado (el offset actual queda clamped al alto mucho menor del
    // spinner y Flutter lo reajusta).
    final isFirstLoad = _manualRecommendations == null && recommendationsAsync.isLoading;
    final isLoading = _isRefreshing || (_manualRecommendations == null && recommendationsAsync.isLoading);
    final baseRecommendations = _manualRecommendations ?? recommendationsAsync.value ?? const [];
    final recommendations = _visibleRecommendations(baseRecommendations);
    // Toda esta sección vive de Deezer: generar el lote, resolver la pista y
    // agregarla a la playlist son operaciones de red, así que sin conexión
    // los controles se apagan en vez de fallar al tocarlos.
    final isConnected = ref.watch(isConnectedProvider).value ?? true;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.surfaceHover),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Recomendaciones',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.primary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Basadas en las canciones y artistas de esta playlist',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppTheme.secondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.primary,
                  side: const BorderSide(color: AppTheme.surfaceHover),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                icon: isLoading
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primary))
                    : Icon(AppIcons.broken(SolarIcons.Refresh), size: 16),
                label: const Text('Actualizar', style: TextStyle(fontSize: 12)),
                onPressed: (isLoading || !isConnected) ? null : _refreshRecommendations,
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (isFirstLoad)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: CircularProgressIndicator(color: AppTheme.primary),
              ),
            )
          else if (recommendations.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text('No hay recomendaciones disponibles en este momento.', style: TextStyle(color: AppTheme.secondary)),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: recommendations.length,
              separatorBuilder: (c, i) => const Divider(height: 8, color: Colors.transparent),
              itemBuilder: (ctx, i) {
                final track = recommendations[i];
                final isThisPreviewPlaying = _activePreviewTrackId == track.id && _isPreviewPlaying;

                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceHover.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: CachedNetworkImage(
                          imageUrl: track.coverUrl,
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                          placeholder: (c, u) => Container(color: AppTheme.surfaceActive),
                          errorWidget: (c, u, e) => Container(
                            color: AppTheme.surfaceActive,
                            child: Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.muted, size: 20),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppTheme.primary,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              track.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: AppTheme.secondary, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Botón Play/Pause preview 30s
                      IconButton(
                        icon: Icon(
                          isThisPreviewPlaying ? AppIcons.bold(SolarIcons.Pause) : AppIcons.broken(SolarIcons.Play),
                          color: isThisPreviewPlaying ? AppTheme.accent : AppTheme.primary,
                          size: 20,
                        ),
                        tooltip: isThisPreviewPlaying
                            ? 'Pausar previsualización'
                            : (isConnected ? 'Escuchar 30s' : 'Sin conexión'),
                        onPressed: isConnected ? () => _togglePreview(track) : null,
                      ),
                      // Botón agregar a playlist
                      IconButton(
                        icon: Icon(
                          AppIcons.broken(SolarIcons.AddCircle),
                          color: isConnected ? AppTheme.primary : AppTheme.muted,
                          size: 22,
                        ),
                        tooltip: isConnected ? 'Agregar a la playlist' : 'Sin conexión',
                        onPressed: isConnected ? () => _addRecommendedTrack(track) : null,
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
