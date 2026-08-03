import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/track_tile.dart';
import '../../player/player_models.dart';
import '../../player/player_providers.dart';

/// Pantalla de Detalle de Álbum (`/album/:id`).
class AlbumDetailScreen extends ConsumerWidget {
  final String albumId;

  const AlbumDetailScreen({
    super.key,
    required this.albumId,
  });

  final List<SyncoraTrack> _mockTracks = const [
    SyncoraTrack(
      id: 'album_t1',
      title: 'Intro - Midnight City',
      artist: 'Cyberbeats',
      album: 'Synthwave Chill',
      duration: Duration(seconds: 145),
      youtubeVideoId: 'dQw4w9WgXcQ',
      artUri: null,
    ),
    SyncoraTrack(
      id: 'album_t2',
      title: 'Neon Horizon',
      artist: 'Cyberbeats',
      album: 'Synthwave Chill',
      duration: Duration(seconds: 210),
      youtubeVideoId: 'dvgZkm1xWPE',
      artUri: null,
    ),
    SyncoraTrack(
      id: 'album_t3',
      title: 'Outrun Drive',
      artist: 'Cyberbeats',
      album: 'Synthwave Chill',
      duration: Duration(seconds: 188),
      youtubeVideoId: 'aFt64QY_sK0',
      artUri: null,
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(syncoraPlayerControllerProvider.notifier);
    final currentTrack = ref.watch(currentTrackProvider);
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    const mockCover = 'https://e-cdns-images.dzcdn.net/images/cover/1db2694b292e85a49806b72a6b2909f8/500x500-000000-80-0-0.jpg';

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: CustomScrollView(
        slivers: [
          // Header full-bleed con portada e info
          SliverAppBar(
            expandedHeight: isDesktop ? 320 : 260,
            pinned: true,
            backgroundColor: AppTheme.surface,
            leading: Padding(
              padding: const EdgeInsets.all(8.0),
              child: CircleAvatar(
                backgroundColor: AppTheme.surfaceHover,
                child: IconButton(
                  icon: const Icon(LucideIcons.chevronLeft, color: AppTheme.primary, size: 20),
                  onPressed: () => context.pop(),
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(
                    imageUrl: mockCover,
                    fit: BoxFit.cover,
                    errorWidget: (context, url, error) => Container(color: AppTheme.surfaceActive),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          AppTheme.background.withValues(alpha: 0.7),
                          AppTheme.background,
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 16,
                    left: isDesktop ? 32 : 20,
                    right: isDesktop ? 32 : 20,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'ÁLBUM',
                          style: TextStyle(
                            color: AppTheme.secondary,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Synthwave Chill',
                          style: TextStyle(
                            color: AppTheme.primary,
                            fontSize: isDesktop ? 36 : 28,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Cyberbeats • 2025 • 3 canciones',
                          style: TextStyle(
                            color: AppTheme.secondary,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Botones de acción principales
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isDesktop ? 32 : 20,
                vertical: 16,
              ),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.primary,
                      boxShadow: AppTheme.glowShadow,
                    ),
                    child: IconButton(
                      icon: const Icon(
                        LucideIcons.play,
                        color: AppTheme.background,
                        size: 26,
                      ),
                      onPressed: () {
                        controller.setQueue(_mockTracks, startIndex: 0);
                        controller.play();
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    icon: const Icon(LucideIcons.shuffle, color: AppTheme.secondary, size: 24),
                    onPressed: () {
                      controller.setQueue(_mockTracks, startIndex: 0);
                      controller.toggleShuffle();
                      controller.play();
                    },
                    tooltip: 'Aleatorio',
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(LucideIcons.arrowDownToLine, color: AppTheme.secondary, size: 24),
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Descargando álbum...')),
                      );
                    },
                    tooltip: 'Descargar',
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(LucideIcons.heart, color: AppTheme.secondary, size: 24),
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Guardado en biblioteca')),
                      );
                    },
                    tooltip: 'Guardar',
                  ),
                ],
              ),
            ),
          ),

          // Lista de pistas
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) {
                  final track = _mockTracks[i];
                  return TrackTile(
                    track: track,
                    index: i,
                    isPlaying: currentTrack?.id == track.id,
                    onTap: () {
                      controller.setQueue(_mockTracks, startIndex: i);
                      controller.play();
                    },
                    onAddToQueue: () => controller.addToQueue(track),
                  );
                },
                childCount: _mockTracks.length,
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }
}
