import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_icons.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/marquee_text.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../player_models.dart';
import '../player_providers.dart';
import '../syncora_player_controller.dart';
import 'queue_view.dart';

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
    return GestureDetector(
      onTap: () => context.push('/player'),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: const BoxDecoration(
          color: AppTheme.primary, // bg-primary
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
                  MarqueeText(
                    text: currentTrack.title,
                    style: const TextStyle(
                      color: AppTheme.background,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  MarqueeText(
                    text: currentTrack.artist,
                    style: TextStyle(
                      color: AppTheme.background.withValues(alpha: 0.7),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),

            // Heart Icon Button (text-background, w-6 h-6)
            _MiniPlayerHeartButton(currentTrack: currentTrack, isDesktop: false),
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
                  isPlaying ? AppIcons.broken(SolarIcons.Pause) : AppIcons.broken(SolarIcons.Play),
                  color: AppTheme.primary,
                  size: 20,
                ),
              ),
            ),
          ],
        ),
      ),
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
          // Izquierda: Portada (56x56) + Info + Heart (flex 1)
          Expanded(
            flex: 1,
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: 280,
                child: _DesktopTrackInfo(currentTrack: currentTrack),
              ),
            ),
          ),

          // Centro: Controles + Barra de progreso (flex 2, centrado exacto)
          Expanded(
            flex: 2,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Botones multimedia (gap-6 = 24px)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: Padding(
                        padding: const EdgeInsets.only(top: 3.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              state.isShuffle ? AppIcons.outline(SolarIcons.Shuffle) : AppIcons.broken(SolarIcons.Shuffle),
                              size: 20,
                              color: state.isShuffle ? Colors.white : AppTheme.secondary,
                            ),
                            const SizedBox(height: 2),
                            Container(
                              width: 4,
                              height: 4,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: state.isShuffle ? Colors.white : Colors.transparent,
                              ),
                            ),
                          ],
                        ),
                      ),
                      onPressed: () => controller.toggleShuffle(),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    const SizedBox(width: 16),
                    IconButton(
                      icon: Icon(AppIcons.broken(SolarIcons.SkipPrevious), size: 20, color: AppTheme.primary),
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
                          isPlaying ? AppIcons.broken(SolarIcons.Pause) : AppIcons.broken(SolarIcons.Play),
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
                      icon: Icon(AppIcons.broken(SolarIcons.SkipNext), size: 20, color: AppTheme.primary),
                      onPressed: () => controller.skipToNext(),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    const SizedBox(width: 16),
                    Builder(
                      builder: (context) {
                        final isRepeatActive = state.repeatMode != SyncoraRepeatMode.off;
                        final repeatIconData = state.repeatMode == SyncoraRepeatMode.one
                            ? (isRepeatActive ? AppIcons.outline(SolarIcons.RepeatOne) : AppIcons.broken(SolarIcons.RepeatOne))
                            : (isRepeatActive ? AppIcons.outline(SolarIcons.Repeat) : AppIcons.broken(SolarIcons.Repeat));
                        return IconButton(
                          icon: Padding(
                            padding: const EdgeInsets.only(top: 3.0),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  repeatIconData,
                                  size: 20,
                                  color: isRepeatActive ? Colors.white : AppTheme.secondary,
                                ),
                                const SizedBox(height: 2),
                                Container(
                                  width: 4,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: isRepeatActive ? Colors.white : Colors.transparent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          onPressed: () => controller.cycleRepeatMode(),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 6),

                // Slider Fino de Progreso
                _DesktopProgressBar(
                  position: position,
                  duration: duration,
                  controller: controller,
                  isPlaying: isPlaying,
                ),
              ],
            ),
          ),

          // Derecha: Letras, Cola, Dispositivos, Volumen (flex 1)
          Expanded(
            flex: 1,
            child: Align(
              alignment: Alignment.centerRight,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: Icon(AppIcons.broken(SolarIcons.Microphone), size: 20, color: AppTheme.secondary),
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
                        ref.watch(isQueueOpenProvider) ? AppIcons.bold(SolarIcons.PlaylistMinimalisticN2) : AppIcons.broken(SolarIcons.PlaylistMinimalisticN2),
                        size: 20,
                        color: ref.watch(isQueueOpenProvider) ? AppTheme.primary : AppTheme.secondary,
                      ),
                      onPressed: () {
                        final isDesktop = MediaQuery.of(context).size.width >= 768;
                        if (isDesktop) {
                          ref.read(isQueueOpenProvider.notifier).state = !ref.read(isQueueOpenProvider);
                        } else {
                          QueueView.showSheet(context);
                        }
                      },
                      tooltip: 'Cola de reproducción',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    ),
                    IconButton(
                      icon: Icon(AppIcons.broken(SolarIcons.Speaker), size: 20, color: AppTheme.secondary),
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
                    IconButton(
                      icon: Icon(
                        state.engine.volume > 0 ? AppIcons.broken(SolarIcons.VolumeLoud) : AppIcons.broken(SolarIcons.VolumeCross),
                        size: 20,
                        color: state.engine.volume > 0 ? AppTheme.secondary : AppTheme.muted,
                      ),
                      onPressed: () {
                        if (state.engine.volume > 0) {
                          controller.setVolume(0.0);
                        } else {
                          controller.setVolume(1.0);
                        }
                      },
                      tooltip: state.engine.volume > 0 ? 'Silenciar' : 'Activar sonido',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    ),
                    const SizedBox(width: 4),
                    _DesktopVolumeSlider(
                      volume: state.engine.volume,
                      onChanged: (val) => controller.setVolume(val),
                    ),
                  ],
                ),
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
      child: Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.muted, size: 24),
    );
  }

}

class _MiniPlayerHeartButton extends ConsumerStatefulWidget {
  final SyncoraTrack currentTrack;
  final bool isDesktop;

  const _MiniPlayerHeartButton({
    required this.currentTrack,
    this.isDesktop = false,
  });

  @override
  ConsumerState<_MiniPlayerHeartButton> createState() => _MiniPlayerHeartButtonState();
}

class _MiniPlayerHeartButtonState extends ConsumerState<_MiniPlayerHeartButton> {
  Future<Playlist>? _likedPlaylistFuture;

  @override
  void initState() {
    super.initState();
    _likedPlaylistFuture = ref.read(playlistDaoProvider).getLikedPlaylist();
  }

  @override
  Widget build(BuildContext context) {
    final dao = ref.watch(playlistDaoProvider);
    final trackIdInt = int.tryParse(widget.currentTrack.id) ?? widget.currentTrack.id.hashCode.abs();

    return FutureBuilder<Playlist>(
      future: _likedPlaylistFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return IconButton(
            icon: Icon(
              AppIcons.broken(SolarIcons.Heart),
              color: widget.isDesktop ? AppTheme.secondary : AppTheme.background,
              size: widget.isDesktop ? 20 : 24,
            ),
            onPressed: null,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(
              minWidth: widget.isDesktop ? 32 : 40,
              minHeight: widget.isDesktop ? 32 : 40,
            ),
          );
        }

        final likedPlaylist = snapshot.data!;
        return StreamBuilder<List<PlaylistTrack>>(
          stream: dao.watchTracksOrdered(likedPlaylist.id),
          builder: (context, tracksSnapshot) {
            final tracks = tracksSnapshot.data ?? [];
            final isLiked = tracks.any((t) => t.trackId == trackIdInt);

            return IconButton(
              icon: Icon(
                isLiked ? AppIcons.bold(SolarIcons.Heart) : AppIcons.broken(SolarIcons.Heart),
                color: isLiked
                    ? (widget.isDesktop ? Colors.white : AppTheme.background)
                    : (widget.isDesktop ? AppTheme.secondary : AppTheme.background),
                size: widget.isDesktop ? 20 : 24,
              ),
              onPressed: () async {
                final isLikedNow = await dao.toggleLikeTrack(
                  trackId: trackIdInt,
                  artistId: 0,
                  albumId: 0,
                  title: widget.currentTrack.title,
                  artistName: widget.currentTrack.artist,
                  albumName: widget.currentTrack.album ?? '',
                  coverUrl: widget.currentTrack.coverUrl,
                  durationMs: (widget.currentTrack.duration ?? Duration.zero).inMilliseconds,
                );

                if (context.mounted) {
                  AppToast.show(
                    context,
                    message: isLikedNow ? 'Se agregó a Tus me gusta.' : 'Se eliminó de Tus me gusta.',
                  );
                }
              },
              padding: EdgeInsets.zero,
              constraints: BoxConstraints(
                minWidth: widget.isDesktop ? 32 : 40,
                minHeight: widget.isDesktop ? 32 : 40,
              ),
            );
          },
        );
      },
    );
  }
}

class _DesktopTrackInfo extends StatefulWidget {
  final SyncoraTrack currentTrack;

  const _DesktopTrackInfo({required this.currentTrack});

  @override
  State<_DesktopTrackInfo> createState() => _DesktopTrackInfoState();
}

class _DesktopTrackInfoState extends State<_DesktopTrackInfo> {
  bool _isAlbumHovered = false;

  @override
  Widget build(BuildContext context) {
    final hasAlbumId = widget.currentTrack.albumId != null && widget.currentTrack.albumId != 0;

    final coverWidget = Hero(
      tag: 'player_cover_hero',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 56,
          height: 56,
          child: widget.currentTrack.coverUrl.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: widget.currentTrack.coverUrl,
                  memCacheWidth: 300,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => _buildPlaceholder(),
                )
              : _buildPlaceholder(),
        ),
      ),
    );

    return Row(
      children: [
        // Portada 56x56 (Enlace a Álbum)
        MouseRegion(
          cursor: hasAlbumId ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) {
            if (hasAlbumId) setState(() => _isAlbumHovered = true);
          },
          onExit: (_) {
            if (hasAlbumId) setState(() => _isAlbumHovered = false);
          },
          child: GestureDetector(
            onTap: hasAlbumId
                ? () => context.push('/album/${widget.currentTrack.albumId}')
                : null,
            child: coverWidget,
          ),
        ),
        const SizedBox(width: 14),

        // Título (Enlace a Álbum) y Artista (Enlace a Artista)
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MouseRegion(
                cursor: hasAlbumId ? SystemMouseCursors.click : SystemMouseCursors.basic,
                onEnter: (_) {
                  if (hasAlbumId) setState(() => _isAlbumHovered = true);
                },
                onExit: (_) {
                  if (hasAlbumId) setState(() => _isAlbumHovered = false);
                },
                child: GestureDetector(
                  onTap: hasAlbumId
                      ? () => context.push('/album/${widget.currentTrack.albumId}')
                      : null,
                  child: MarqueeText(
                    text: widget.currentTrack.title,
                    style: TextStyle(
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      decoration: (hasAlbumId && _isAlbumHovered) ? TextDecoration.underline : TextDecoration.none,
                      decorationColor: AppTheme.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2),

              // Artistas
              _buildArtistSubtitle(context),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _MiniPlayerHeartButton(currentTrack: widget.currentTrack, isDesktop: true),
      ],
    );
  }

  Widget _buildArtistSubtitle(BuildContext context) {
    const style = TextStyle(
      color: AppTheme.secondary,
      fontSize: 12,
    );

    final List<SyncoraArtistRef> effectiveArtists = [];
    if (widget.currentTrack.artists.isNotEmpty) {
      effectiveArtists.addAll(widget.currentTrack.artists);
    } else if (widget.currentTrack.artist.contains(', ')) {
      final names = widget.currentTrack.artist.split(', ');
      final mainId = widget.currentTrack.artistId ?? 0;
      for (int i = 0; i < names.length; i++) {
        effectiveArtists.add(SyncoraArtistRef(
          id: i == 0 ? mainId : 0,
          name: names[i].trim(),
        ));
      }
    }

    if (effectiveArtists.isNotEmpty) {
      final spans = <InlineSpan>[];
      for (int i = 0; i < effectiveArtists.length; i++) {
        final artist = effectiveArtists[i];
        if (i > 0) {
          spans.add(
            const TextSpan(
              text: ', ',
              style: style,
            ),
          );
        }
        final isClickable = artist.id != 0;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _MiniPlayerHoverableArtist(
              text: artist.name,
              style: style,
              isClickable: isClickable,
              onTap: isClickable ? () => context.push('/artist/${artist.id}') : null,
            ),
          ),
        );
      }

      return Text.rich(
        TextSpan(children: spans),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    final hasArtistId = widget.currentTrack.artistId != null && widget.currentTrack.artistId != 0;

    if (hasArtistId) {
      return Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _MiniPlayerHoverableArtist(
                text: widget.currentTrack.artist,
                style: style,
                isClickable: true,
                onTap: () => context.push('/artist/${widget.currentTrack.artistId}'),
              ),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    return MarqueeText(
      text: widget.currentTrack.artist,
      style: style,
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: AppTheme.surfaceHover,
      child: Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.muted, size: 24),
    );
  }
}

class _MiniPlayerHoverableArtist extends StatefulWidget {
  final String text;
  final TextStyle style;
  final bool isClickable;
  final VoidCallback? onTap;

  const _MiniPlayerHoverableArtist({
    required this.text,
    required this.style,
    required this.isClickable,
    this.onTap,
  });

  @override
  State<_MiniPlayerHoverableArtist> createState() => _MiniPlayerHoverableArtistState();
}

class _MiniPlayerHoverableArtistState extends State<_MiniPlayerHoverableArtist> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.isClickable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (widget.isClickable) setState(() => _isHovered = true);
      },
      onExit: (_) {
        if (widget.isClickable) setState(() => _isHovered = false);
      },
      child: GestureDetector(
        onTap: widget.isClickable ? widget.onTap : null,
        child: Text(
          widget.text,
          style: widget.style.copyWith(
            decoration: (widget.isClickable && _isHovered) ? TextDecoration.underline : TextDecoration.none,
            decorationColor: widget.style.color,
          ),
        ),
      ),
    );
  }
}

class _DesktopProgressBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final SyncoraPlayerController controller;
  final bool isPlaying;

  const _DesktopProgressBar({
    required this.position,
    required this.duration,
    required this.controller,
    required this.isPlaying,
  });

  @override
  State<_DesktopProgressBar> createState() => _DesktopProgressBarState();
}

class _DesktopProgressBarState extends State<_DesktopProgressBar> {
  bool _isDragging = false;
  bool _isHovered = false;
  double _dragRatio = 0.0;
  bool _wasPlayingBeforeDrag = false;

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final durationMs = widget.duration.inMilliseconds;
    final currentMs = widget.position.inMilliseconds;
    final realRatio = durationMs > 0 ? (currentMs / durationMs).clamp(0.0, 1.0) : 0.0;
    final effectiveRatio = _isDragging ? _dragRatio : realRatio;

    final currentDisplayDuration = _isDragging
        ? Duration(milliseconds: (_dragRatio * durationMs).toInt())
        : widget.position;

    return Row(
      children: [
        Text(
          _formatDuration(currentDisplayDuration),
          style: const TextStyle(color: AppTheme.secondary, fontSize: 11, fontWeight: FontWeight.w500),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: MouseRegion(
            onEnter: (_) => setState(() => _isHovered = true),
            onExit: (_) => setState(() => _isHovered = false),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: (_isHovered || _isDragging) ? 6 : 4,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: (_isHovered || _isDragging) ? 6 : 0),
                overlayShape: RoundSliderOverlayShape(overlayRadius: (_isHovered || _isDragging) ? 12 : 0),
                activeTrackColor: AppTheme.primary,
                inactiveTrackColor: AppTheme.surface,
                thumbColor: AppTheme.primary,
              ),
              child: Slider(
                value: effectiveRatio,
                onChangeStart: (val) {
                  setState(() {
                    _isDragging = true;
                    _dragRatio = val;
                    _wasPlayingBeforeDrag = widget.isPlaying;
                  });
                  if (widget.isPlaying) {
                    widget.controller.pause();
                  }
                },
                onChanged: (val) {
                  setState(() {
                    _dragRatio = val;
                  });
                },
                onChangeEnd: (val) async {
                  final targetMs = (val * durationMs).toInt();
                  await widget.controller.seek(Duration(milliseconds: targetMs));
                  if (mounted) {
                    setState(() {
                      _isDragging = false;
                    });
                  }
                  if (_wasPlayingBeforeDrag) {
                    widget.controller.play();
                  }
                },
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _formatDuration(widget.duration),
          style: const TextStyle(color: AppTheme.secondary, fontSize: 11, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

class _DesktopVolumeSlider extends StatefulWidget {
  final double volume;
  final ValueChanged<double> onChanged;

  const _DesktopVolumeSlider({
    required this.volume,
    required this.onChanged,
  });

  @override
  State<_DesktopVolumeSlider> createState() => _DesktopVolumeSliderState();
}

class _DesktopVolumeSliderState extends State<_DesktopVolumeSlider> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: SizedBox(
        width: 140,
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: _isHovered ? 6 : 0),
            activeTrackColor: AppTheme.primary,
            inactiveTrackColor: AppTheme.surface,
            thumbColor: Colors.white,
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
          ),
          child: Slider(
            value: widget.volume.clamp(0.0, 1.0),
            onChanged: widget.onChanged,
          ),
        ),
      ),
    );
  }
}


