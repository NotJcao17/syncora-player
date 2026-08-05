import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_icons.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_bottom_sheet.dart';
import '../../../core/widgets/track_tile.dart';
import '../../../data/local_db/database_provider.dart';
import '../player_models.dart';
import '../player_providers.dart';
import '../syncora_player_controller.dart';
import '../widgets/lyrics_sheet.dart';

/// Reproductor Fullscreen Inmersivo con soporte para Karaoke sincronizado y Me Gusta persistente.
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isLikedNow ? 'Añadido a Tus me gusta' : 'Eliminado de Tus me gusta'),
          duration: const Duration(seconds: 1),
        ),
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

                  const SizedBox(height: 24),

                  // Portada Centrada (260x260px)
                  Hero(
                    tag: 'player_cover_hero',
                    child: Center(
                      child: Container(
                        width: 260,
                        height: 260,
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
                          _isLiked ? AppIcons.bold(SolarIcons.Heart) : AppIcons.broken(SolarIcons.Heart),
                          color: _isLiked ? Colors.white : AppTheme.secondary,
                          size: 28,
                        ),
                        onPressed: () => _toggleLike(currentTrack),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // Barra de reproducción interactiva
                  _buildProceduralWaveform(context, state, currentTrack, controller),

                  const SizedBox(height: 24),

                  // Controles Multimedia Principales
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: Icon(
                          state.isShuffle ? AppIcons.bold(SolarIcons.Shuffle) : AppIcons.broken(SolarIcons.Shuffle),
                          color: state.isShuffle ? Colors.white : AppTheme.secondary,
                          size: 24,
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
                        width: 80,
                        height: 80,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppTheme.primary,
                          boxShadow: AppTheme.glowHighShadow,
                        ),
                        child: IconButton(
                          icon: Icon(
                            isPlaying ? AppIcons.broken(SolarIcons.Pause) : AppIcons.broken(SolarIcons.Play),
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
                      IconButton(
                        icon: Icon(AppIcons.broken(SolarIcons.SkipNext), color: AppTheme.primary, size: 36),
                        onPressed: () => controller.skipToNext(),
                        tooltip: 'Siguiente',
                      ),
                      IconButton(
                        icon: Icon(
                          state.repeatMode == SyncoraRepeatMode.one
                              ? (state.repeatMode != SyncoraRepeatMode.off ? AppIcons.bold(SolarIcons.RepeatOne) : AppIcons.broken(SolarIcons.RepeatOne))
                              : (state.repeatMode != SyncoraRepeatMode.off ? AppIcons.bold(SolarIcons.Repeat) : AppIcons.broken(SolarIcons.Repeat)),
                          color: state.repeatMode != SyncoraRepeatMode.off ? Colors.white : AppTheme.secondary,
                          size: 24,
                        ),
                        onPressed: () => controller.cycleRepeatMode(),
                        tooltip: 'Repetir',
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

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

    final currentMs = position.inMilliseconds.toDouble().clamp(0.0, duration.inMilliseconds.toDouble());
    final totalMs = duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 180000.0;

    return Column(
      children: [
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 4,
            activeTrackColor: AppTheme.primary,
            inactiveTrackColor: AppTheme.surfaceHover,
            thumbColor: AppTheme.primary,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayColor: AppTheme.primary.withValues(alpha: 0.2),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: currentMs,
            min: 0.0,
            max: totalMs,
            onChanged: (val) {
              controller.seek(Duration(milliseconds: val.toInt()));
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(position),
                style: const TextStyle(color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.w600),
              ),
              Text(
                _formatDuration(duration),
                style: const TextStyle(color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCoverPlaceholder() {
    return Container(
      color: AppTheme.surfaceHover,
      child: Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.muted, size: 80),
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
    AppBottomSheet.show(
      context: context,
      title: track.title,
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: Icon(AppIcons.broken(SolarIcons.AddFolder), color: AppTheme.primary),
            title: const Text('Agregar a playlist', style: TextStyle(color: AppTheme.primary)),
            onTap: () {
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }
}
