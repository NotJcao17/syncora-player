import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import '../../../core/theme/app_icons.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/marquee_text.dart';
import '../../../data/local_db/database_provider.dart';
import '../audio_engine/audio_engine_state.dart';
import '../player_models.dart';
import '../player_providers.dart';
import '../syncora_player_controller.dart';
import '../widgets/lyrics_sheet.dart';
import '../widgets/queue_view.dart';

/// Reproductor Fullscreen Inmersivo con soporte para Karaoke sincronizado y Me Gusta persistente.
class PlayerFullscreenScreen extends ConsumerStatefulWidget {
  const PlayerFullscreenScreen({super.key});

  @override
  ConsumerState<PlayerFullscreenScreen> createState() => _PlayerFullscreenScreenState();
}

class _PlayerFullscreenScreenState extends ConsumerState<PlayerFullscreenScreen> {
  Color? _dominantColor;
  bool _isLiked = false;
  double _dragOffsetY = 0.0;

  @override
  void initState() {
    super.initState();
    _extractPalette();
    _checkIsLiked();
  }

  Future<void> _checkIsLiked() async {
    final track = ref.read(currentTrackProvider);
    if (track == null) return;
    final trackIdInt = int.tryParse(track.id) ?? track.id.hashCode.abs();
    final dao = ref.read(playlistDaoProvider);
    final liked = await dao.isTrackLiked(trackIdInt);
    if (mounted) setState(() => _isLiked = liked);
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
    } catch (_) {}
  }

  Future<void> _toggleLike(SyncoraTrack track) async {
    final trackIdInt = int.tryParse(track.id) ?? track.id.hashCode.abs();
    final dao = ref.read(playlistDaoProvider);
    final isLikedNow = await dao.toggleLikeTrack(
      trackId: trackIdInt,
      artistId: 0,
      albumId: 0,
      title: track.title,
      artistName: track.artist,
      albumName: track.album ?? '',
      coverUrl: track.coverUrl,
      durationMs: (track.duration ?? Duration.zero).inMilliseconds,
    );

    if (mounted) {
      setState(() => _isLiked = isLikedNow);
      AppToast.show(
        context,
        message: isLikedNow ? 'Se agregó a Tus me gusta.' : 'Se eliminó de Tus me gusta.',
      );
    }
  }

  void _showLyricsSheet(BuildContext context, SyncoraTrack track) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => LyricsSheet(track: track),
    );
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
            icon: Icon(AppIcons.broken(SolarIcons.AltArrowDown), color: AppTheme.primary),
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
        onVerticalDragUpdate: (details) {
          if (details.delta.dy > 0 || _dragOffsetY > 0) {
            setState(() {
              _dragOffsetY = (_dragOffsetY + details.delta.dy).clamp(0.0, 500.0);
            });
          }
        },
        onVerticalDragEnd: (details) {
          if (_dragOffsetY > 140 || (details.primaryVelocity != null && details.primaryVelocity! > 300)) {
            context.pop();
          } else {
            setState(() {
              _dragOffsetY = 0.0;
            });
          }
        },
        child: AnimatedContainer(
          duration: _dragOffsetY > 0 ? Duration.zero : const Duration(milliseconds: 250),
          transform: Matrix4.translationValues(0, _dragOffsetY, 0),
          decoration: BoxDecoration(
            borderRadius: _dragOffsetY > 0
                ? const BorderRadius.vertical(top: Radius.circular(24))
                : BorderRadius.zero,
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
          clipBehavior: _dragOffsetY > 0 ? Clip.antiAlias : Clip.none,
          child: Opacity(
            opacity: (1.0 - (_dragOffsetY / 450.0)).clamp(0.0, 1.0),
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final availableHeight = constraints.maxHeight;
                  final coverSize = (availableHeight * 0.35).clamp(180.0, 320.0);

                  return SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: availableHeight - 24.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Top Header
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconButton(
                                icon: Icon(AppIcons.broken(SolarIcons.AltArrowDown), color: AppTheme.primary, size: 24),
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
                                icon: Icon(AppIcons.broken(SolarIcons.MenuDots), color: AppTheme.primary, size: 24),
                                onPressed: () => _showTrackOptionsMenu(context, currentTrack),
                                tooltip: 'Opciones',
                              ),
                            ],
                          ),

                          const SizedBox(height: 12),

                          // Portada Centrada y Escalable
                          Hero(
                            tag: 'player_cover_hero',
                            child: Center(
                              child: Container(
                                width: coverSize,
                                height: coverSize,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(24),
                                  boxShadow: AppTheme.glowHighShadow,
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(24),
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

                          const SizedBox(height: 16),

                          // Info de pista: Título, Artista, Me Gusta
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    MarqueeText(
                                      text: currentTrack.title,
                                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: AppTheme.primary,
                                            fontSize: 22,
                                          ) ?? const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.primary),
                                    ),
                                    const SizedBox(height: 4),
                                    MarqueeText(
                                      text: currentTrack.artist,
                                      style: const TextStyle(
                                        color: AppTheme.secondary,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: Icon(
                                  _isLiked ? AppIcons.bold(SolarIcons.Heart) : AppIcons.broken(SolarIcons.Heart),
                                  color: _isLiked ? Colors.white : AppTheme.secondary,
                                  size: 28,
                                ),
                                onPressed: () => _toggleLike(currentTrack),
                              ),
                            ],
                          ),

                          const SizedBox(height: 12),

                          // Barra de reproducción interactiva
                          _FullscreenSeekBar(
                            position: state.engine.position,
                            duration: state.engine.duration.inSeconds > 0
                                ? state.engine.duration
                                : (currentTrack.duration != null && currentTrack.duration!.inSeconds > 0
                                    ? currentTrack.duration!
                                    : const Duration(seconds: 180)),
                            track: currentTrack,
                            controller: controller,
                            isPlaying: isPlaying,
                          ),

                          const SizedBox(height: 12),

                          // Controles Multimedia Principales
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconButton(
                                icon: Padding(
                                  padding: const EdgeInsets.only(top: 3.0),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        state.isShuffle ? AppIcons.outline(SolarIcons.Shuffle) : AppIcons.broken(SolarIcons.Shuffle),
                                        color: state.isShuffle ? Colors.white : AppTheme.secondary,
                                        size: 24,
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
                                tooltip: 'Aleatorio',
                              ),
                              IconButton(
                                icon: Icon(AppIcons.broken(SolarIcons.SkipPrevious), color: AppTheme.primary, size: 36),
                                onPressed: () => controller.skipToPrevious(),
                                tooltip: 'Anterior',
                              ),
                              Container(
                                width: 76,
                                height: 76,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppTheme.primary,
                                  boxShadow: AppTheme.glowHighShadow,
                                ),
                                child: Material(
                                  color: Colors.transparent,
                                  shape: const CircleBorder(),
                                  clipBehavior: Clip.antiAlias,
                                  child: IconButton(
                                    style: IconButton.styleFrom(
                                      shape: const CircleBorder(),
                                      padding: EdgeInsets.zero,
                                    ),
                                    icon: (state.engine.processingState == AudioProcessingState.loading ||
                                            state.engine.processingState == AudioProcessingState.buffering)
                                        ? LoadingAnimationWidget.threeArchedCircle(
                                            color: AppTheme.background,
                                            size: 34,
                                          )
                                        : Icon(
                                            isPlaying ? AppIcons.broken(SolarIcons.Pause) : AppIcons.broken(SolarIcons.Play),
                                            color: AppTheme.background,
                                            size: 38,
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
                              ),
                              IconButton(
                                icon: Icon(AppIcons.broken(SolarIcons.SkipNext), color: AppTheme.primary, size: 36),
                                onPressed: () => controller.skipToNext(),
                                tooltip: 'Siguiente',
                              ),
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
                                            color: isRepeatActive ? Colors.white : AppTheme.secondary,
                                            size: 24,
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
                                    tooltip: 'Repetir',
                                  );
                                },
                              ),
                            ],
                          ),

                          const SizedBox(height: 12),

                          // Botones Inferiores: Letras (LRCLib real) & Cola
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              TextButton.icon(
                                onPressed: () => _showLyricsSheet(context, currentTrack),
                                icon: Icon(AppIcons.broken(SolarIcons.AlignLeft), size: 18, color: AppTheme.secondary),
                                label: const Text('Letras', style: TextStyle(color: AppTheme.secondary)),
                              ),
                              IconButton(
                                icon: Icon(AppIcons.broken(SolarIcons.PlaylistMinimalisticN2), size: 22, color: AppTheme.secondary),
                                onPressed: () => QueueView.showSheet(context),
                                tooltip: 'Ver cola',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCoverPlaceholder() {
    return Container(
      color: AppTheme.surfaceHover,
      child: Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.muted, size: 80),
    );
  }


  void _showTrackOptionsMenu(BuildContext context, SyncoraTrack track) {
    final controller = ref.read(syncoraPlayerControllerProvider.notifier);
    AppBottomSheet.show(
      context: context,
      title: track.title,
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: Icon(AppIcons.broken(SolarIcons.PlayCircle), color: AppTheme.primary),
            title: const Text('Reproducir a continuación', style: TextStyle(color: AppTheme.primary)),
            onTap: () {
              controller.playNext(track);
              Navigator.pop(context);
              AppToast.show(context, message: 'Se reproducirá a continuación');
            },
          ),
          ListTile(
            leading: Icon(AppIcons.broken(SolarIcons.AddFolder), color: AppTheme.primary),
            title: const Text('Agregar a la cola', style: TextStyle(color: AppTheme.primary)),
            onTap: () {
              controller.addToQueue(track);
              Navigator.pop(context);
              AppToast.show(context, message: 'Se agregó a la cola');
            },
          ),
        ],
      ),
    );
  }
}

class _FullscreenSeekBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final SyncoraTrack track;
  final SyncoraPlayerController controller;
  final bool isPlaying;

  const _FullscreenSeekBar({
    required this.position,
    required this.duration,
    required this.track,
    required this.controller,
    required this.isPlaying,
  });

  @override
  State<_FullscreenSeekBar> createState() => _FullscreenSeekBarState();
}

class _FullscreenSeekBarState extends State<_FullscreenSeekBar> {
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
    final durationMs = widget.duration.inMilliseconds > 0 ? widget.duration.inMilliseconds.toDouble() : 180000.0;
    final currentMs = widget.position.inMilliseconds.toDouble().clamp(0.0, durationMs);
    final realRatio = (currentMs / durationMs).clamp(0.0, 1.0);
    final effectiveRatio = _isDragging ? _dragRatio : realRatio;

    final currentDisplayDuration = _isDragging
        ? Duration(milliseconds: (_dragRatio * durationMs).toInt())
        : widget.position;

    return Column(
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: (_isHovered || _isDragging) ? 6 : 4,
              activeTrackColor: AppTheme.primary,
              inactiveTrackColor: AppTheme.surfaceHover,
              thumbColor: AppTheme.primary,
              thumbShape: RoundSliderThumbShape(enabledThumbRadius: (_isHovered || _isDragging) ? 7 : 4),
              overlayColor: AppTheme.primary.withValues(alpha: 0.2),
              overlayShape: RoundSliderOverlayShape(overlayRadius: (_isHovered || _isDragging) ? 14 : 8),
            ),
            child: Slider(
              value: effectiveRatio,
              min: 0.0,
              max: 1.0,
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
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(currentDisplayDuration),
                style: const TextStyle(color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.w600),
              ),
              Text(
                _formatDuration(widget.duration),
                style: const TextStyle(color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

