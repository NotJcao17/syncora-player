import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/skeleton_box.dart';
import '../../player/player_models.dart';
import '../../player/player_providers.dart';

/// Pantalla de Detalle de Playlist (`/playlist/:id`).
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
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _isLoading = false);
    });
  }

  final List<SyncoraTrack> _mockTracks = [
    SyncoraTrack(
      id: 'pl_track_1',
      title: 'Rick Astley - Never Gonna Give You Up',
      artist: 'Rick Astley',
      album: 'Whenever You Need Somebody',
      duration: const Duration(seconds: 213),
      youtubeVideoId: 'dQw4w9WgXcQ',
      artUri: Uri.parse('https://e-cdns-images.dzcdn.net/images/cover/2e018122cb56986277102d2041a592c8/500x500-000000-80-0-0.jpg'),
    ),
    SyncoraTrack(
      id: 'pl_track_2',
      title: 'Coldplay - Viva La Vida',
      artist: 'Coldplay',
      album: 'Viva La Vida',
      duration: const Duration(seconds: 242),
      youtubeVideoId: 'dvgZkm1xWPE',
      artUri: Uri.parse('https://e-cdns-images.dzcdn.net/images/cover/1db2694b292e85a49806b72a6b2909f8/500x500-000000-80-0-0.jpg'),
    ),
    SyncoraTrack(
      id: 'pl_track_3',
      title: 'Danny Ocean - Dembow',
      artist: 'Danny Ocean',
      album: '54+1',
      duration: const Duration(seconds: 217),
      youtubeVideoId: 'aFt64QY_sK0',
      artUri: Uri.parse('https://e-cdns-images.dzcdn.net/images/cover/6c2057bb081b29a28c2c19e7cf23927d/500x500-000000-80-0-0.jpg'),
    ),
    SyncoraTrack(
      id: 'pl_track_4',
      title: 'Track No Disponible en tu Región',
      artist: 'Artista Desconocido',
      album: 'Álbum Bloqueado',
      duration: const Duration(seconds: 195),
      youtubeVideoId: 'blocked_id',
      artUri: null,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(syncoraPlayerControllerProvider.notifier);
    final currentTrack = ref.watch(currentTrackProvider);
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    final title = widget.playlistId == 'liked' ? 'Canciones que me gustan' : 'Neon Shadows';
    final description = widget.playlistId == 'liked'
        ? 'Tus canciones favoritas guardadas en la biblioteca.'
        : 'Una playlist electrónica conceptual con bajos profundos y voces etéreas. Perfecta para viajes nocturnos.';
    final coverUrl = widget.playlistId == 'liked'
        ? 'https://images.unsplash.com/photo-1514525253161-7a46d19cd819?q=80&w=800&auto=format&fit=crop'
        : 'https://images.unsplash.com/photo-1614613535308-eb5fbd3d2c17?q=80&w=800&auto=format&fit=crop';

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

                    // Header Info (Móvil centrado / Desktop horizontal calcado de image5 / playlist.html)
                    if (isDesktop)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          // Cover 256x256
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
                          // Detalle a la izquierda
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'PLAYLIST',
                                  style: TextStyle(
                                    color: AppTheme.secondary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.5,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  title,
                                  style: const TextStyle(
                                    color: AppTheme.primary,
                                    fontSize: 52,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -1,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  description,
                                  style: const TextStyle(
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
                                        imageUrl: 'https://i.pravatar.cc/150?img=11',
                                        width: 24,
                                        height: 24,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Text('Alex Doe', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 14)),
                                    const Text('  •  4 canciones  •  14 min', style: TextStyle(color: AppTheme.secondary, fontSize: 14)),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    else
                      // Móvil Centrado (Imagen 5)
                      Column(
                        children: [
                          // Cover disco centrado 192x192
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
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: AppTheme.primary,
                              fontSize: 32,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            description,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
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
                                  imageUrl: 'https://i.pravatar.cc/150?img=11',
                                  width: 20,
                                  height: 20,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Text('Alex Doe', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 13)),
                              const Text(' • 4 canciones • 14 min', style: TextStyle(color: AppTheme.secondary, fontSize: 13)),
                            ],
                          ),
                        ],
                      ),

                    const SizedBox(height: 24),

                    // Fila de Botones de Acción (Play blanco grande, shuffle, download, heart, options)
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
                                    const SnackBar(content: Text('Descargando playlist...')),
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
                    _isLoading
                        ? ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: 4,
                            separatorBuilder: (ctx, index) => const SizedBox(height: 8),
                            itemBuilder: (ctx, index) => const SkeletonBox(height: 60, borderRadius: 12),
                          )
                        : ListView.separated(
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
                                      // Portada 48x48
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: SizedBox(
                                          width: 48,
                                          height: 48,
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              CachedNetworkImage(
                                                imageUrl: track.coverUrl,
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
                                      // Título y Artista
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              track.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: isPlaying ? AppTheme.primary : AppTheme.primary,
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
                                      // Duración y More options
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
