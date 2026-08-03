import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/track_tile.dart';
import '../player_models.dart';
import '../player_providers.dart';
import '../syncora_player_controller.dart';

/// Reproductor Fullscreen Inmersivo.
class PlayerFullscreenScreen extends ConsumerStatefulWidget {
  const PlayerFullscreenScreen({super.key});

  @override
  ConsumerState<PlayerFullscreenScreen> createState() => _PlayerFullscreenScreenState();
}

class _PlayerFullscreenScreenState extends ConsumerState<PlayerFullscreenScreen> {
  Color? _dominantColor;
  bool _isLiked = false;

  @override
  void initState() {
    super.initState();
    _extractPalette();
  }

  void _extractPalette() async {
    final track = ref.read(currentTrackProvider);
    if (track == null || track.coverUrl.isEmpty) return;

    try {
      final palette = await PaletteGenerator.fromImageProvider(
        NetworkImage(track.coverUrl),
        maximumColorCount: 8,
      );
      if (mounted && palette.dominantColor != null) {
        setState(() {
          _dominantColor = palette.dominantColor!.color;
        });
      }
    } catch (_) {
      // Ignorar si falla la extracción
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentTrack = ref.watch(currentTrackProvider);
    final isPlaying = ref.watch(isPlayingProvider);
    final state = ref.watch(playerStateProvider);
    final controller = ref.watch(syncoraPlayerControllerProvider.notifier);

    if (currentTrack == null) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(LucideIcons.chevronDown, color: AppTheme.primary),
            onPressed: () => context.pop(),
          ),
        ),
        body: const Center(
          child: Text('No hay pista en reproducción', style: TextStyle(color: AppTheme.secondary)),
        ),
      );
    }

    final dominantGradientColor = _dominantColor?.withValues(alpha: 0.35) ?? AppTheme.surfaceHover.withValues(alpha: 0.3);

    return Scaffold(
      body: GestureDetector(
        onVerticalDragEnd: (details) {
          if (details.primaryVelocity != null && details.primaryVelocity! > 300) {
            context.pop();
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 500),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                dominantGradientColor,
                AppTheme.background,
                AppTheme.background,
              ],
            ),
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
              child: Column(
                children: [
                  // Top Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: const Icon(LucideIcons.chevronDown, color: AppTheme.primary, size: 24),
                        onPressed: () => context.pop(),
                        tooltip: 'Minimizar',
                      ),
                      const Column(
                        children: [
                          Text(
                            'REPRODUCIENDO DESDE',
                            style: TextStyle(
                              color: AppTheme.secondary,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.5,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Cola de Syncora',
                            style: TextStyle(
                              color: AppTheme.primary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(LucideIcons.moreHorizontal, color: AppTheme.primary, size: 24),
                        onPressed: () => _showTrackOptionsMenu(context, currentTrack),
                        tooltip: 'Opciones',
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // Portada Centrada (rounded-3xl = 24px) con glowHighShadow
                  Hero(
                    tag: 'player_cover_hero',
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: AppTheme.glowHighShadow,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: AspectRatio(
                          aspectRatio: 1.0,
                          child: currentTrack.coverUrl.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: currentTrack.coverUrl,
                                  memCacheWidth: 600,
                                  fit: BoxFit.cover,
                                  errorWidget: (context, url, error) => _buildCoverPlaceholder(),
                                )
                              : _buildCoverPlaceholder(),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 28),

                  // Info de pista: Título, Artista, Me Gusta
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              currentTrack.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: AppTheme.primary,
                                    fontSize: 24,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              currentTrack.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppTheme.secondary,
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          _isLiked ? LucideIcons.heart : LucideIcons.heart,
                          color: _isLiked ? AppTheme.primary : AppTheme.secondary,
                          size: 26,
                        ),
                        onPressed: () {
                          setState(() {
                            _isLiked = !_isLiked;
                          });
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(_isLiked
                                  ? 'Añadido a Me Gusta'
                                  : 'Eliminado de Me Gusta'),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // Waveform Procedural Decorativo
                  _buildProceduralWaveform(context, state, currentTrack, controller),

                  const SizedBox(height: 24),

                  // Controles Multimedia Principales (Play 80x80, Skips 40x40)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Toggle Shuffle
                      IconButton(
                        icon: Icon(
                          LucideIcons.shuffle,
                          color: state.isShuffle ? Colors.white : AppTheme.secondary,
                          size: 24,
                        ),
                        onPressed: () => controller.toggleShuffle(),
                        tooltip: 'Aleatorio',
                      ),

                      // Previous (w-10 h-10 = 40x40)
                      IconButton(
                        icon: const Icon(LucideIcons.skipBack, color: AppTheme.primary, size: 36),
                        onPressed: () => controller.skipToPrevious(),
                        tooltip: 'Anterior',
                      ),

                      // Play/Pause circular 80x80 con shadow-glow-high
                      Container(
                        width: 80,
                        height: 80,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppTheme.primary,
                          boxShadow: AppTheme.glowHighShadow,
                        ),
                        child: IconButton(
                          icon: Icon(
                            isPlaying ? LucideIcons.pause : LucideIcons.play,
                            color: AppTheme.background,
                            size: 40,
                          ),
                          onPressed: () {
                            if (isPlaying) {
                              controller.pause();
                            } else {
                              controller.play();
                            }
                          },
                          tooltip: isPlaying ? 'Pausar' : 'Reproducir',
                        ),
                      ),

                      // Next (w-10 h-10 = 40x40)
                      IconButton(
                        icon: const Icon(LucideIcons.skipForward, color: AppTheme.primary, size: 36),
                        onPressed: () => controller.skipToNext(),
                        tooltip: 'Siguiente',
                      ),

                      // Repeat Mode
                      IconButton(
                        icon: Icon(
                          state.repeatMode == SyncoraRepeatMode.one
                              ? LucideIcons.repeat1
                              : LucideIcons.repeat,
                          color: state.repeatMode != SyncoraRepeatMode.off ? Colors.white : AppTheme.secondary,
                          size: 24,
                        ),
                        onPressed: () => controller.cycleRepeatMode(),
                        tooltip: 'Repetir',
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // Botones Inferiores Secundarios: Letras & Cola
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Letras próximamente (LRCLib)')),
                          );
                        },
                        icon: const Icon(LucideIcons.alignLeft, size: 18, color: AppTheme.secondary),
                        label: const Text('Letras', style: TextStyle(color: AppTheme.secondary)),
                      ),
                      IconButton(
                        icon: const Icon(LucideIcons.listMusic, size: 22, color: AppTheme.secondary),
                        onPressed: () => _showQueueSheet(context, state, controller),
                        tooltip: 'Ver cola',
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Waveform procedural interactivo (reemplaza barra de progreso lisa)
  Widget _buildProceduralWaveform(
    BuildContext context,
    SyncoraPlayerState state,
    SyncoraTrack currentTrack,
    SyncoraPlayerController controller,
  ) {
    final position = state.engine.position;
    final trackDuration = currentTrack.duration;
    final duration = state.engine.duration.inSeconds > 0
        ? state.engine.duration
        : (trackDuration != null && trackDuration.inSeconds > 0 ? trackDuration : const Duration(seconds: 180));

    final progressRatio = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    const barCount = 36;
    final seed = currentTrack.id.hashCode;

    return Column(
      children: [
        GestureDetector(
          onTapDown: (details) {
            final width = context.size?.width ?? 300;
            final dx = details.localPosition.dx.clamp(0.0, width);
            final ratio = dx / width;
            final targetMs = (ratio * duration.inMilliseconds).toInt();
            controller.seek(Duration(milliseconds: targetMs));
          },
          onHorizontalDragUpdate: (details) {
            final width = context.size?.width ?? 300;
            final dx = details.localPosition.dx.clamp(0.0, width);
            final ratio = dx / width;
            final targetMs = (ratio * duration.inMilliseconds).toInt();
            controller.seek(Duration(milliseconds: targetMs));
          },
          child: Container(
            height: 48,
            color: Colors.transparent,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: List.generate(barCount, (i) {
                final barRatio = i / barCount;
                final isFilled = barRatio <= progressRatio;
                // Generar altura pseudoaleatoria pero consistente por canción
                final heightFactor = 0.2 + (((seed * (i + 1) * 31) % 80) / 100.0);
                final barHeight = 48.0 * heightFactor;

                return Container(
                  width: 4,
                  height: barHeight,
                  decoration: BoxDecoration(
                    color: isFilled ? AppTheme.primary : AppTheme.secondary.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              }),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _formatDuration(position),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12),
            ),
            Text(
              _formatDuration(duration),
              style: const TextStyle(color: AppTheme.muted, fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCoverPlaceholder() {
    return Container(
      color: AppTheme.surfaceHover,
      child: const Icon(LucideIcons.music, color: AppTheme.muted, size: 80),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _showQueueSheet(
    BuildContext context,
    SyncoraPlayerState state,
    SyncoraPlayerController controller,
  ) {
    final queue = state.queue;
    final currentIndex = state.currentIndex;

    AppBottomSheet.show(
      context: context,
      title: 'Cola de Reproducción (${queue.length})',
      child: queue.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(24.0),
              child: Text('La cola está vacía', textAlign: TextAlign.center),
            )
          : ListView.builder(
              itemCount: queue.length,
              itemBuilder: (ctx, i) {
                final track = queue[i];
                final isCurrent = i == currentIndex;
                return TrackTile(
                  track: track,
                  index: i,
                  isPlaying: isCurrent,
                  onTap: () {
                    controller.skipToQueueIndex(i);
                    Navigator.pop(ctx);
                  },
                );
              },
            ),
    );
  }

  void _showTrackOptionsMenu(BuildContext context, SyncoraTrack track) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.folderPlus, color: AppTheme.primary),
              title: const Text('Agregar a playlist'),
              onTap: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Próximamente')),
                );
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.disc, color: AppTheme.primary),
              title: const Text('Ver álbum'),
              onTap: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Próximamente')),
                );
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.user, color: AppTheme.primary),
              title: const Text('Ver artista'),
              onTap: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Próximamente')),
                );
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.wrench, color: AppTheme.primary),
              title: const Text('Corregir coincidencia de YT (Fix Match)'),
              onTap: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Próximamente')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
