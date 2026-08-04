import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/error_state.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/models/deezer/deezer_album.dart';
import '../../player/player_models.dart';
import '../../player/player_providers.dart';

/// Pantalla de Detalle de Álbum (`/album/:id`) conectada a Deezer real.
class AlbumDetailScreen extends ConsumerStatefulWidget {
  final String albumId;

  const AlbumDetailScreen({
    super.key,
    required this.albumId,
  });

  @override
  ConsumerState<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends ConsumerState<AlbumDetailScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  DeezerAlbum? _album;
  bool _isSaved = false;

  @override
  void initState() {
    super.initState();
    _loadAlbumData();
  }

  Future<void> _loadAlbumData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final id = int.tryParse(widget.albumId) ?? 0;
    if (id == 0) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'ID de álbum inválido';
      });
      return;
    }

    try {
      final api = ref.read(deezerApiProvider);
      final album = await api.getAlbum(id);
      final savedDao = ref.read(savedAlbumDaoProvider);
      final isSaved = await savedDao.isAlbumSaved(id);

      if (mounted) {
        setState(() {
          _album = album;
          _isSaved = isSaved;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Error al cargar los detalles del álbum.';
        });
      }
    }
  }

  Future<void> _toggleSaveAlbum() async {
    if (_album == null) return;
    final savedDao = ref.read(savedAlbumDaoProvider);
    final nowSaved = await savedDao.toggleSaveAlbum(
      albumId: _album!.id,
      title: _album!.title,
      artistName: _album!.artistName,
      coverUrl: _album!.coverUrl,
    );

    if (mounted) {
      setState(() => _isSaved = nowSaved);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(nowSaved ? 'Álbum guardado en tu biblioteca' : 'Álbum eliminado de tu biblioteca'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(syncoraPlayerControllerProvider.notifier);
    final currentTrack = ref.watch(currentTrackProvider);
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    if (_isLoading) {
      return const Scaffold(
        backgroundColor: AppTheme.background,
        body: Center(child: CircularProgressIndicator(color: AppTheme.primary)),
      );
    }

    if (_errorMessage != null || _album == null) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        body: ErrorStateWidget(
          message: _errorMessage ?? 'No se encontró el álbum',
          onRetry: _loadAlbumData,
        ),
      );
    }

    final album = _album!;
    final syncoraTracks = album.tracks.map((t) => t.toSyncoraTrack()).toList();

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 56,
                left: isDesktop ? 32 : 20,
                right: isDesktop ? 32 : 20,
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
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: CachedNetworkImage(
                              imageUrl: album.coverUrl,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        const SizedBox(width: 28),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'ÁLBUM',
                                style: TextStyle(
                                  color: AppTheme.secondary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.5,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                album.title,
                                style: const TextStyle(
                                  color: AppTheme.primary,
                                  fontSize: 44,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -1,
                                ),
                              ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  Text(
                                    album.artistName,
                                    style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                  Text(
                                    '  •  ${album.releaseDate}  •  ${album.trackCount} canciones',
                                    style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  else
                    Column(
                      children: [
                        Container(
                          width: 180,
                          height: 180,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: AppTheme.glowHighShadow,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: CachedNetworkImage(
                              imageUrl: album.coverUrl,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          album.title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppTheme.primary,
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              album.artistName,
                              style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            Text(
                              ' • ${album.trackCount} canciones',
                              style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                            ),
                          ],
                        ),
                      ],
                    ),

                  const SizedBox(height: 24),

                  Row(
                    children: [
                      if (syncoraTracks.isNotEmpty) ...[
                        Container(
                          width: 56,
                          height: 56,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppTheme.primary,
                            boxShadow: AppTheme.glowShadow,
                          ),
                          child: IconButton(
                            icon: const Icon(LucideIcons.play, color: AppTheme.background, size: 26),
                            onPressed: () {
                              controller.setQueue(syncoraTracks, startIndex: 0);
                              controller.play();
                            },
                          ),
                        ),
                        const SizedBox(width: 16),
                        IconButton(
                          icon: const Icon(LucideIcons.shuffle, color: AppTheme.primary, size: 24),
                          onPressed: () {
                            controller.setQueue(syncoraTracks, startIndex: 0);
                            controller.toggleShuffle();
                            controller.play();
                          },
                          tooltip: 'Aleatorio',
                        ),
                        const SizedBox(width: 16),
                      ],
                      IconButton(
                        icon: Icon(
                          _isSaved ? LucideIcons.heartHandshake : LucideIcons.heart,
                          color: _isSaved ? AppTheme.primary : AppTheme.secondary,
                          size: 24,
                        ),
                        onPressed: _toggleSaveAlbum,
                        tooltip: _isSaved ? 'Eliminar de guardados' : 'Guardar álbum',
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: syncoraTracks.length,
                    itemBuilder: (ctx, i) {
                      final track = syncoraTracks[i];
                      final isPlaying = currentTrack?.id == track.id;

                      return _AlbumTrackRow(
                        track: track,
                        index: i + 1,
                        isPlaying: isPlaying,
                        isDesktop: isDesktop,
                        onTap: () {
                          controller.setQueue(syncoraTracks, startIndex: i);
                          controller.play();
                        },
                        formatDuration: _formatDuration,
                      );
                    },
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
                    icon: const Icon(LucideIcons.chevronLeft, color: AppTheme.primary, size: 20),
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
                    icon: const Icon(LucideIcons.search, color: AppTheme.primary, size: 18),
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
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _AlbumTrackRow extends StatefulWidget {
  final SyncoraTrack track;
  final int index;
  final bool isPlaying;
  final bool isDesktop;
  final VoidCallback onTap;
  final String Function(Duration) formatDuration;

  const _AlbumTrackRow({
    required this.track,
    required this.index,
    required this.isPlaying,
    required this.isDesktop,
    required this.onTap,
    required this.formatDuration,
  });

  @override
  State<_AlbumTrackRow> createState() => _AlbumTrackRowState();
}

class _AlbumTrackRowState extends State<_AlbumTrackRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final isPlaying = widget.isPlaying;

    final bgColor = isPlaying
        ? AppTheme.surfaceHover
        : (_isHovered ? AppTheme.surfaceHover.withValues(alpha: 0.5) : Colors.transparent);

    return InkWell(
      onTap: widget.onTap,
      onHover: (h) {
        if (mounted && _isHovered != h) setState(() => _isHovered = h);
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: Center(
                child: isPlaying
                    ? const Icon(LucideIcons.chartColumn, color: AppTheme.primary, size: 16)
                    : Text(
                        '${widget.index}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppTheme.secondary, fontSize: 13, fontWeight: FontWeight.w600),
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
                    style: TextStyle(
                      color: isPlaying ? AppTheme.primary : AppTheme.primary.withValues(alpha: 0.95),
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.secondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              widget.formatDuration(track.duration ?? Duration.zero),
              style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
