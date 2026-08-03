import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/skeleton_box.dart';
import '../../../core/widgets/track_tile.dart';
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

    final mockTitle = widget.playlistId == 'liked' ? 'Canciones que me gustan' : 'Top Éxitos Syncora';
    final mockSubtitle = widget.playlistId == 'liked' ? 'Tus canciones guardadas' : 'Creado por Syncora • 4 canciones • 14 min';
    final mockCover = widget.playlistId == 'liked'
        ? 'https://images.unsplash.com/photo-1514525253161-7a46d19cd819?q=80&w=800&auto=format&fit=crop'
        : 'https://e-cdns-images.dzcdn.net/images/cover/2e018122cb56986277102d2041a592c8/500x500-000000-80-0-0.jpg';

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
                          'PLAYLIST',
                          style: TextStyle(
                            color: AppTheme.secondary,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          mockTitle,
                          style: TextStyle(
                            color: AppTheme.primary,
                            fontSize: isDesktop ? 36 : 28,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          mockSubtitle,
                          style: const TextStyle(
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
                  // Botón Play redondo blanco con shadow-glow
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
                        final validTracks = _mockTracks.where((t) => t.id != 'pl_track_4').toList();
                        controller.setQueue(validTracks, startIndex: 0);
                        controller.play();
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    icon: const Icon(LucideIcons.shuffle, color: AppTheme.secondary, size: 24),
                    onPressed: () {
                      final validTracks = _mockTracks.where((t) => t.id != 'pl_track_4').toList();
                      controller.setQueue(validTracks, startIndex: 0);
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
                        const SnackBar(content: Text('Descargando playlist...')),
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

          // Lista de Pistas
          if (_isLoading)
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, index) => const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: SkeletonBox(height: 56, borderRadius: 8),
                  ),
                  childCount: 4,
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) {
                    final track = _mockTracks[i];
                    final isAvailable = track.id != 'pl_track_4';
                    final isPlaying = currentTrack?.id == track.id;

                    return TrackTile(
                      track: track,
                      index: i,
                      isPlaying: isPlaying,
                      isAvailable: isAvailable,
                      onTap: () {
                        if (!isAvailable) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Esta pista no está disponible')),
                          );
                          return;
                        }
                        final validTracks = _mockTracks.where((t) => t.id != 'pl_track_4').toList();
                        final validIndex = validTracks.indexWhere((t) => t.id == track.id);
                        controller.setQueue(validTracks, startIndex: validIndex >= 0 ? validIndex : 0);
                        controller.play();
                      },
                      onAddToQueue: isAvailable ? () => controller.addToQueue(track) : null,
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
