import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/theme/app_theme.dart';
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

    const title = 'Synthwave Chill';
    const artistName = 'Cyberbeats';
    const coverUrl = 'https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?q=80&w=800&auto=format&fit=crop';

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            // Top Bar Sticky: Botón Atrás (<) a la izquierda, Botón Buscar (🔍) a la derecha
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.surface.withValues(alpha: 0.8),
                    ),
                    child: IconButton(
                      icon: const Icon(LucideIcons.chevronLeft, color: AppTheme.primary, size: 22),
                      onPressed: () => context.pop(),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.surface.withValues(alpha: 0.8),
                    ),
                    child: IconButton(
                      icon: const Icon(LucideIcons.search, color: AppTheme.primary, size: 20),
                      onPressed: () => context.push('/search'),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
                child: Column(
                  children: [
                    const SizedBox(height: 8),

                    // Header Info
                    if (isDesktop)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Container(
                            width: 256,
                            height: 256,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: AppTheme.glowShadow,
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: CachedNetworkImage(
                                imageUrl: coverUrl,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          const SizedBox(width: 32),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'ÁLBUM',
                                  style: TextStyle(
                                    color: AppTheme.secondary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.5,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  title,
                                  style: TextStyle(
                                    color: AppTheme.primary,
                                    fontSize: 52,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -1,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                const Text(
                                  'Un viaje sonoro retro-futurista con sintetizadores análogos.',
                                  style: TextStyle(
                                    color: AppTheme.secondary,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius: const BorderRadius.all(Radius.circular(999)),
                                      child: CachedNetworkImage(
                                        imageUrl: 'https://i.pravatar.cc/150?img=33',
                                        width: 24,
                                        height: 24,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Text(artistName, style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 14)),
                                    const Text('  •  2025  •  3 canciones  •  9 min', style: TextStyle(color: AppTheme.secondary, fontSize: 14)),
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
                            width: 192,
                            height: 192,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: AppTheme.glowHighShadow,
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: CachedNetworkImage(
                                imageUrl: coverUrl,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            title,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppTheme.primary,
                              fontSize: 32,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Un viaje sonoro retro-futurista con sintetizadores análogos.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppTheme.secondary,
                              fontSize: 13,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              ClipRRect(
                                borderRadius: const BorderRadius.all(Radius.circular(999)),
                                child: CachedNetworkImage(
                                  imageUrl: 'https://i.pravatar.cc/150?img=33',
                                  width: 20,
                                  height: 20,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Text(artistName, style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 13)),
                              const Text(' • 2025 • 3 canciones', style: TextStyle(color: AppTheme.secondary, fontSize: 13)),
                            ],
                          ),
                        ],
                      ),

                    const SizedBox(height: 24),

                    // Botones de acción
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
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
                                icon: const Icon(LucideIcons.play, color: AppTheme.background, size: 26),
                                onPressed: () {
                                  controller.setQueue(_mockTracks, startIndex: 0);
                                  controller.play();
                                },
                              ),
                            ),
                            const SizedBox(width: 16),
                            IconButton(
                              icon: const Icon(LucideIcons.shuffle, color: AppTheme.primary, size: 26),
                              onPressed: () {
                                controller.setQueue(_mockTracks, startIndex: 0);
                                controller.toggleShuffle();
                                controller.play();
                              },
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: AppTheme.surfaceActive, width: 1),
                              ),
                              child: IconButton(
                                icon: const Icon(LucideIcons.arrowDownToLine, color: AppTheme.secondary, size: 18),
                                onPressed: () {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Descargando álbum...')),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: AppTheme.surfaceActive, width: 1),
                              ),
                              child: IconButton(
                                icon: const Icon(LucideIcons.heart, color: AppTheme.secondary, size: 18),
                                onPressed: () {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Guardado en biblioteca')),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              icon: const Icon(LucideIcons.ellipsis, color: AppTheme.secondary, size: 24),
                              onPressed: () {},
                            ),
                          ],
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // Lista de Canciones
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _mockTracks.length,
                      separatorBuilder: (ctx, index) => const SizedBox(height: 8),
                      itemBuilder: (ctx, i) {
                        final track = _mockTracks[i];
                        final isPlaying = currentTrack?.id == track.id;

                        return InkWell(
                          onTap: () {
                            controller.setQueue(_mockTracks, startIndex: i);
                            controller.play();
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: AppTheme.surface,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        CachedNetworkImage(
                                          imageUrl: coverUrl,
                                          fit: BoxFit.cover,
                                        ),
                                        if (isPlaying)
                                          Container(
                                            color: Colors.black.withValues(alpha: 0.5),
                                            child: const Icon(LucideIcons.chartColumn, color: Colors.white, size: 20),
                                          ),
                                      ],
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
                                          color: AppTheme.primary,
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
                                  _formatDuration(track.duration ?? Duration.zero),
                                  style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  icon: const Icon(LucideIcons.ellipsis, color: AppTheme.secondary, size: 20),
                                  onPressed: () {},
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
