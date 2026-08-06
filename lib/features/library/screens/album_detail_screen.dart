import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_icons.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/track_tile.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/models/deezer/deezer_album.dart';
import '../../../data/models/deezer/deezer_track.dart';
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
      AppToast.show(
        context,
        message: nowSaved ? 'Álbum guardado en tu biblioteca' : 'Álbum eliminado de tu biblioteca',
      );
    }
  }

  String _formatTotalDuration(List<DeezerTrack> tracks) {
    final totalSec = tracks.fold<int>(0, (sum, t) => sum + t.durationSec);
    final minutes = totalSec ~/ 60;
    final seconds = totalSec % 60;
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final remMin = minutes % 60;
      return '$hours h $remMin min';
    }
    return '$minutes min $seconds s';
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
    final totalDurationStr = _formatTotalDuration(album.tracks);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
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
                                    '  •  ${album.releaseDate}  •  ${album.tracks.length} canciones, $totalDurationStr',
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
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: CachedNetworkImage(
                                imageUrl: album.coverUrl,
                                fit: BoxFit.cover,
                              ),
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
                              ' • ${album.tracks.length} canciones, $totalDurationStr',
                              style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                            ),
                          ],
                        ),
                      ],
                    ),

                  const SizedBox(height: 16),

                  Row(
                    mainAxisAlignment: isDesktop ? MainAxisAlignment.start : MainAxisAlignment.center,
                    children: [
                      if (syncoraTracks.isNotEmpty) ...[
                        _HeaderPlayButton(
                          onPressed: () {
                            controller.setQueue(syncoraTracks, startIndex: 0);
                            controller.play();
                          },
                        ),
                        const SizedBox(width: 16),
                        IconButton(
                          icon: Icon(AppIcons.broken(SolarIcons.Shuffle), color: AppTheme.primary, size: 24),
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
                          _isSaved ? AppIcons.bold(SolarIcons.Heart) : AppIcons.broken(SolarIcons.Heart),
                          color: _isSaved ? AppTheme.primary : AppTheme.secondary,
                          size: 24,
                        ),
                        onPressed: _toggleSaveAlbum,
                        tooltip: _isSaved ? 'Eliminar de guardados' : 'Guardar álbum',
                      ),
                    ],
                  ),

                  const SizedBox(height: 20), // Top padding before track list

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
                      final isPlaying = currentTrack?.id == track.id;

                      return TrackTile(
                        track: track,
                        index: i,
                        isPlaying: isPlaying,
                        showAlbum: true,
                        onTap: () {
                          controller.setQueue(syncoraTracks, startIndex: i);
                          controller.play();
                        },
                        onAddToQueue: () => controller.addToQueue(track),
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
  }
}

class _HeaderPlayButton extends StatefulWidget {
  final VoidCallback onPressed;

  const _HeaderPlayButton({required this.onPressed});

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
            icon: Icon(AppIcons.outline(SolarIcons.Play), color: AppTheme.background, size: 26),
            onPressed: widget.onPressed,
          ),
        ),
      ),
    );
  }
}
