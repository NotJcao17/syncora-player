import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/track_tile.dart';
import '../player_models.dart';
import '../player_providers.dart';
import '../syncora_player_controller.dart';

/// Mini-reproductor siempre visible si hay una pista activa (Diseño pixel-perfect de image2.png / index.html mockup).
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTrack = ref.watch(currentTrackProvider);
    final isPlaying = ref.watch(isPlayingProvider);
    final controller = ref.watch(syncoraPlayerControllerProvider.notifier);
    final state = ref.watch(playerStateProvider);

    final isDesktop = MediaQuery.of(context).size.width >= 768;
    final isVisible = currentTrack != null;

    if (!isVisible) return const SizedBox.shrink();

    return Material(
      color: isDesktop ? AppTheme.surface : Colors.transparent,
      elevation: isDesktop ? 12 : 0,
      child: isDesktop
          ? _buildDesktopBar(context, ref, currentTrack, isPlaying, controller, state)
          : _buildMobileBar(context, ref, currentTrack, isPlaying, controller),
    );
  }

  /// Layout Móvil: tarjeta blanca premium (bg-primary text-background) con bordes
  /// redondeados superiores de 24px, calcada del mockup index.html.
  Widget _buildMobileBar(
    BuildContext context,
    WidgetRef ref,
    SyncoraTrack currentTrack,
    bool isPlaying,
    SyncoraPlayerController controller,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => context.push('/player'),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            decoration: const BoxDecoration(
              color: AppTheme.primary, // bg-primary (blanco)
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              boxShadow: AppTheme.miniPlayerShadow,
            ),
            child: Row(
              children: [
                // Portada 48x48 (w-12 h-12 rounded-lg) con Hero tag
                Hero(
                  tag: 'player_cover_hero',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: currentTrack.coverUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: currentTrack.coverUrl,
                              memCacheWidth: 300,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => _buildPlaceholder(),
                            )
                          : _buildPlaceholder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),

                // Título y Artista truncados (text-background / text-background/70)
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        currentTrack.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.background,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        currentTrack.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.background.withValues(alpha: 0.7),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),

                // Heart Icon Button (text-background, w-6 h-6)
                IconButton(
                  icon: const Icon(
                    LucideIcons.heart,
                    color: AppTheme.background,
                    size: 24,
                  ),
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Guardado en Me Gusta')),
                    );
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                ),
                const SizedBox(width: 8),

                // Play/Pause circular (bg-background text-primary, w-5 h-5)
                GestureDetector(
                  onTap: () {
                    if (isPlaying) {
                      controller.pause();
                    } else {
                      controller.play();
                    }
                  },
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.background,
                    ),
                    child: Icon(
                      isPlaying ? LucideIcons.pause : LucideIcons.play,
                      color: AppTheme.primary,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Extensión blanca inferior que rellena el área detrás de las esquinas redondeadas de _MobileNavBar
        Container(
          height: 16,
          color: AppTheme.primary,
        ),
      ],
    );
  }

  /// Layout Desktop: barra inferior completa (idéntica a image2.png / mockup HTML index.html)
  Widget _buildDesktopBar(
    BuildContext context,
    WidgetRef ref,
    SyncoraTrack currentTrack,
    bool isPlaying,
    SyncoraPlayerController controller,
    SyncoraPlayerState state,
  ) {
    final position = state.engine.position;
    final trackDuration = currentTrack.duration;
    final duration = state.engine.duration.inSeconds > 0
        ? state.engine.duration
        : (trackDuration != null && trackDuration.inSeconds > 0 ? trackDuration : const Duration(seconds: 180));

    final progressRatio = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      height: 96,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: AppTheme.surfaceHover,
        border: Border(top: BorderSide(color: AppTheme.surface, width: 1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Izquierda: Portada (56x56) + Info + Heart
          Expanded(
            flex: 3,
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => context.push('/player'),
                  child: Hero(
                    tag: 'player_cover_hero',
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox(
                        width: 56,
                        height: 56,
                        child: currentTrack.coverUrl.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: currentTrack.coverUrl,
                                memCacheWidth: 300,
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => _buildPlaceholder(),
                              )
                            : _buildPlaceholder(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Flexible(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        currentTrack.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        currentTrack.artist,
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
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(LucideIcons.heart, size: 16, color: AppTheme.secondary),
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Guardado en Me Gusta')),
                    );
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ],
            ),
          ),

          // Centro: Controles + Barra de progreso
          Expanded(
            flex: 5,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Botones multimedia (gap-6 = 24px)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: Icon(
                        LucideIcons.shuffle,
                        size: 16,
                        color: state.isShuffle ? Colors.white : AppTheme.secondary,
                      ),
                      onPressed: () => controller.toggleShuffle(),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    const SizedBox(width: 16),
                    IconButton(
                      icon: const Icon(LucideIcons.skipBack, size: 20, color: AppTheme.primary),
                      onPressed: () => controller.skipToPrevious(),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    const SizedBox(width: 16),
                    // Botón Play redondo blanco 40x40 con shadow-glow
                    Container(
                      width: 40,
                      height: 40,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppTheme.primary,
                        boxShadow: AppTheme.glowShadow,
                      ),
                      child: IconButton(
                        icon: Icon(
                          isPlaying ? LucideIcons.pause : LucideIcons.play,
                          color: AppTheme.background,
                          size: 20,
                        ),
                        onPressed: () {
                          if (isPlaying) {
                            controller.pause();
                          } else {
                            controller.play();
                          }
                        },
                        padding: EdgeInsets.zero,
                      ),
                    ),
                    const SizedBox(width: 16),
                    IconButton(
                      icon: const Icon(LucideIcons.skipForward, size: 20, color: AppTheme.primary),
                      onPressed: () => controller.skipToNext(),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    const SizedBox(width: 16),
                    IconButton(
                      icon: Icon(
                        LucideIcons.repeat,
                        size: 16,
                        color: state.repeatMode != SyncoraRepeatMode.off ? Colors.white : AppTheme.secondary,
                      ),
                      onPressed: () => controller.cycleRepeatMode(),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                  ],
                ),
                const SizedBox(height: 6),

                // Slider Fino de Progreso
                Row(
                  children: [
                    Text(
                      _formatDuration(position),
                      style: const TextStyle(color: AppTheme.secondary, fontSize: 11, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 6,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 0),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 6),
                          activeTrackColor: AppTheme.primary,
                          inactiveTrackColor: AppTheme.surface,
                        ),
                        child: Slider(
                          value: progressRatio,
                          onChanged: (val) {
                            final targetMs = (val * duration.inMilliseconds).toInt();
                            controller.seek(Duration(milliseconds: targetMs));
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatDuration(duration),
                      style: const TextStyle(color: AppTheme.secondary, fontSize: 11, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Derecha: Letras, Cola, Dispositivos, Volumen
          Expanded(
            flex: 3,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(LucideIcons.mic2, size: 16, color: AppTheme.secondary),
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Letras próximamente')),
                      );
                    },
                    tooltip: 'Letras',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  ),
                  IconButton(
                    icon: Icon(
                      LucideIcons.listMusic,
                      size: 16,
                      color: ref.watch(isQueueOpenProvider) ? AppTheme.primary : AppTheme.secondary,
                    ),
                    onPressed: () {
                      final isDesktop = MediaQuery.of(context).size.width >= 768;
                      if (isDesktop) {
                        ref.read(isQueueOpenProvider.notifier).state = !ref.read(isQueueOpenProvider);
                      } else {
                        _showQueueSheet(context, ref);
                      }
                    },
                    tooltip: 'Cola de reproducción',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.speaker, size: 16, color: AppTheme.secondary),
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Conectar dispositivo')),
                      );
                    },
                    tooltip: 'Dispositivos',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  ),
                  const SizedBox(width: 4),
                  const Icon(LucideIcons.volume2, size: 16, color: AppTheme.secondary),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 96,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 0),
                        activeTrackColor: AppTheme.primary,
                        inactiveTrackColor: AppTheme.surface,
                      ),
                      child: Slider(
                        value: state.engine.volume,
                        onChanged: (val) => controller.setVolume(val),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: AppTheme.surfaceHover,
      child: const Icon(LucideIcons.music, color: AppTheme.muted, size: 24),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _showQueueSheet(BuildContext context, WidgetRef ref) {
    final state = ref.read(playerStateProvider);
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
                    ref.read(syncoraPlayerControllerProvider.notifier).skipToQueueIndex(i);
                    Navigator.pop(ctx);
                  },
                );
              },
            ),
    );
  }
}
