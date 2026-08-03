import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/playlist_card.dart';
import '../../../core/widgets/track_tile.dart';
import '../../player/player_models.dart';
import '../../player/player_providers.dart';

/// Pantalla de Detalle de Artista (`/artist/:id`).
class ArtistDetailScreen extends ConsumerWidget {
  final String artistId;

  const ArtistDetailScreen({
    super.key,
    required this.artistId,
  });

  final List<SyncoraTrack> _mockTopTracks = const [
    SyncoraTrack(
      id: 'artist_t1',
      title: 'Blinding Lights',
      artist: 'The Weeknd',
      album: 'After Hours',
      duration: Duration(seconds: 200),
      youtubeVideoId: '4NRXx6U8ABQ',
      artUri: null,
    ),
    SyncoraTrack(
      id: 'artist_t2',
      title: 'Starboy (feat. Daft Punk)',
      artist: 'The Weeknd',
      album: 'Starboy',
      duration: Duration(seconds: 230),
      youtubeVideoId: '34Na4j8AVgA',
      artUri: null,
    ),
  ];

  final List<Map<String, String>> _mockAlbums = const [
    {
      'id': 'album_1',
      'title': 'After Hours',
      'subtitle': 'Álbum • 2020',
      'cover': 'https://e-cdns-images.dzcdn.net/images/cover/1db2694b292e85a49806b72a6b2909f8/500x500-000000-80-0-0.jpg',
    },
    {
      'id': 'album_2',
      'title': 'Starboy',
      'subtitle': 'Álbum • 2016',
      'cover': 'https://e-cdns-images.dzcdn.net/images/cover/2e018122cb56986277102d2041a592c8/500x500-000000-80-0-0.jpg',
    },
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(syncoraPlayerControllerProvider.notifier);
    final currentTrack = ref.watch(currentTrackProvider);
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: CustomScrollView(
        slivers: [
          // Header con foto grande y gradiente
          SliverAppBar(
            backgroundColor: AppTheme.surface,
            expandedHeight: isDesktop ? 340 : 280,
            pinned: true,
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
                    imageUrl: 'https://images.unsplash.com/photo-1549834125-82d3c48159a3?q=80&w=800&auto=format&fit=crop',
                    memCacheWidth: 600,
                    fit: BoxFit.cover,
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
                    bottom: 20,
                    left: isDesktop ? 32 : 20,
                    right: isDesktop ? 32 : 20,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(LucideIcons.checkCircle2, color: AppTheme.primary, size: 16),
                            const SizedBox(width: 6),
                            const Text(
                              'ARTISTA VERIFICADO',
                              style: TextStyle(
                                color: AppTheme.primary,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'The Weeknd',
                          style: TextStyle(
                            color: AppTheme.primary,
                            fontSize: isDesktop ? 44 : 32,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '85,420,100 oyentes mensuales',
                          style: TextStyle(color: AppTheme.secondary, fontSize: 14),
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
                        controller.setQueue(_mockTopTracks, startIndex: 0);
                        controller.play();
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  OutlinedButton(
                    onPressed: () {},
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppTheme.surfaceHover),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    ),
                    child: const Text(
                      'Siguiendo',
                      style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Sección Top Canciones
          SliverPadding(
            padding: EdgeInsets.symmetric(
              horizontal: isDesktop ? 32 : 20,
              vertical: 12,
            ),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Canciones populares',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ),

          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) {
                  final track = _mockTopTracks[i];
                  return TrackTile(
                    track: track,
                    index: i,
                    isPlaying: currentTrack?.id == track.id,
                    onTap: () {
                      controller.setQueue(_mockTopTracks, startIndex: i);
                      controller.play();
                    },
                    onAddToQueue: () => controller.addToQueue(track),
                  );
                },
                childCount: _mockTopTracks.length,
              ),
            ),
          ),

          // Sección Discografía (Carrusel horizontal)
          SliverPadding(
            padding: EdgeInsets.symmetric(
              horizontal: isDesktop ? 32 : 20,
              vertical: 20,
            ),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Discografía',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 220,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _mockAlbums.length,
                      separatorBuilder: (ctx, index) => const SizedBox(width: 16),
                      itemBuilder: (ctx, i) {
                        final album = _mockAlbums[i];
                        return SizedBox(
                          width: isDesktop ? 192 : 144,
                          child: PlaylistCard(
                            title: album['title']!,
                            subtitle: album['subtitle']!,
                            coverUrl: album['cover'],
                            onTap: () => context.push('/album/${album['id']}'),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }
}
