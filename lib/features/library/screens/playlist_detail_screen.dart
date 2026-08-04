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
      body: Stack(
        children: [
          // Fondo con resplandor ambiental brillante en la parte superior
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFF38234C),
                    Color(0xFF1E283C),
                    AppTheme.background,
                  ],
                  stops: [0.0, 0.35, 0.75],
                ),
              ),
            ),
          ),

          // ScrollView ocupando toda la pantalla desde arriba
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

                  // Header Info (Desktop horizontal / Móvil centrado)
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
                              imageUrl: coverUrl,
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
                                title,
                                style: const TextStyle(
                                  color: AppTheme.primary,
                                  fontSize: 44,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -1,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                description,
                                style: const TextStyle(
                                  color: AppTheme.secondary,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 14),
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
                                  const Text('Alex Doe', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 13)),
                                  const Text('  •  4 canciones  •  14 min', style: TextStyle(color: AppTheme.secondary, fontSize: 13)),
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
                              imageUrl: coverUrl,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          title,
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
                          description,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppTheme.secondary,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 10),
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

                  // Fila de Botones de Acción (Imagen 2: Iconos limpios sin bordes circulares)
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
                        icon: const Icon(LucideIcons.shuffle, color: AppTheme.primary, size: 24),
                        onPressed: () {
                          controller.setQueue(_mockTracks, startIndex: 0);
                          controller.toggleShuffle();
                          controller.play();
                        },
                        tooltip: 'Aleatorio',
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        icon: const Icon(LucideIcons.arrowDownToLine, color: AppTheme.secondary, size: 20),
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Descargando playlist...')),
                          );
                        },
                        tooltip: 'Descargar',
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(LucideIcons.heart, color: AppTheme.secondary, size: 20),
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Guardado en biblioteca')),
                          );
                        },
                        tooltip: 'Guardar',
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(LucideIcons.ellipsis, color: AppTheme.secondary, size: 20),
                        onPressed: () {},
                        tooltip: 'Más opciones',
                      ),
                    ],
                  ),

                  SizedBox(height: isDesktop ? 24 : 8),

                  // Cabecera de Tabla en Desktop (Imagen 2)
                  if (isDesktop) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 32,
                            child: Center(
                              child: Text('#', style: TextStyle(color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.bold)),
                            ),
                          ),
                          Expanded(
                            flex: 4,
                            child: Text('Título', style: TextStyle(color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text('Álbum', style: TextStyle(color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                          SizedBox(
                            width: 100,
                            child: Text('Fecha', style: TextStyle(color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                          SizedBox(
                            width: 80,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Icon(LucideIcons.clock, color: AppTheme.muted, size: 14),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(color: AppTheme.surfaceActive, height: 1),
                    const SizedBox(height: 8),
                  ],

                  // Lista de Canciones
                  _isLoading
                      ? ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: 4,
                          separatorBuilder: (ctx, index) => const SizedBox(height: 4),
                          itemBuilder: (ctx, index) => const SkeletonBox(height: 52, borderRadius: 8),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _mockTracks.length,
                          itemBuilder: (ctx, i) {
                            final track = _mockTracks[i];
                            final isPlaying = currentTrack?.id == track.id;

                            return _PlaylistTrackRow(
                              track: track,
                              index: i + 1,
                              isPlaying: isPlaying,
                              isDesktop: isDesktop,
                              onTap: () {
                                controller.setQueue(_mockTracks, startIndex: i);
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

          // Botones Flotantes Superiores Glassmorphism (Sin barra de fondo que tape el scroll!)
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

/// Fila individual de canción (Centrado de número/icono ecualizador y menú de 3 puntos)
class _PlaylistTrackRow extends StatefulWidget {
  final SyncoraTrack track;
  final int index;
  final bool isPlaying;
  final bool isDesktop;
  final VoidCallback onTap;
  final String Function(Duration) formatDuration;

  const _PlaylistTrackRow({
    required this.track,
    required this.index,
    required this.isPlaying,
    required this.isDesktop,
    required this.onTap,
    required this.formatDuration,
  });

  @override
  State<_PlaylistTrackRow> createState() => _PlaylistTrackRowState();
}

class _PlaylistTrackRowState extends State<_PlaylistTrackRow> {
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
        padding: EdgeInsets.only(
          left: 12,
          right: widget.isDesktop ? 12 : 2,
          top: 8,
          bottom: 8,
        ),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            // Índice o Icono de Ecualizador Centrado (Fix Imagen 5)
            if (widget.isDesktop)
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

            // Cover (40x40)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 40,
                height: 40,
                child: CachedNetworkImage(
                  imageUrl: track.coverUrl,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 12),

            // Título y Artista
            Expanded(
              flex: widget.isDesktop ? 4 : 1,
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

            // Álbum en Desktop
            if (widget.isDesktop) ...[
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: Text(
                  track.album ?? 'Álbum',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                ),
              ),
              const SizedBox(width: 12),
              const SizedBox(
                width: 100,
                child: Text(
                  '11/07/2025',
                  style: TextStyle(color: AppTheme.secondary, fontSize: 13),
                ),
              ),
            ],

            const SizedBox(width: 12),
            // Duración y Menú de 3 Puntos
            if (widget.isDesktop)
              SizedBox(
                width: 80,
                child: Row(
                  children: [
                    Text(
                      widget.formatDuration(track.duration ?? Duration.zero),
                      style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                    ),
                    const Spacer(),
                    if (_isHovered || isPlaying)
                      IconButton(
                        icon: const Icon(LucideIcons.ellipsis, color: AppTheme.secondary, size: 18),
                        onPressed: () {},
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      )
                    else
                      const SizedBox(width: 28),
                  ],
                ),
              )
            else
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.formatDuration(track.duration ?? Duration.zero),
                    style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    icon: const Icon(LucideIcons.ellipsisVertical, color: AppTheme.secondary, size: 18),
                    onPressed: () {},
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
