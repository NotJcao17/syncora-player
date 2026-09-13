import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import '../../../core/theme/app_icons.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../../core/layout/bottom_chrome_metrics.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/marquee_text.dart';
import '../../../core/widgets/track_tile.dart' show TrackContextMenu;
import '../../auth/local_mode_provider.dart';
import '../../library/services/like_track_service.dart';
import '../../../core/widgets/track_cover_image.dart';
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

  /// Id de la pista dueña del color de fondo vigente. Ronda 3 (H-R3-4): la
  /// paleta se extraía **solo en `initState`**, así que con la pantalla
  /// abierta el fondo se quedaba con el color de la pista que sonaba al
  /// abrirla. De ahí el caso reportado en pruebas: portada roja con el fondo
  /// completamente verde, que era el de un álbum vecino en la cola.
  ///
  /// También sirve de guard de carrera: `PaletteGenerator` es asíncrono y
  /// puede resolver cuando ya suena otra pista; una respuesta que no
  /// corresponde al id vigente se descarta en vez de pisar el color bueno.
  String? _paletteTrackId;

  /// Mismo problema y mismo patrón para el corazón: sin esto se quedaba con
  /// el estado "me gusta" de la pista con la que se abrió la pantalla.
  String? _likedTrackId;

  /// Generación de la consulta de "me gusta". Sin esto, tocar el corazón
  /// mientras una consulta para la MISMA pista sigue en vuelo dejaba que la
  /// respuesta vieja pisara el valor recién escrito (la comparación por id no
  /// distingue esos dos casos porque el id es el mismo).
  int _likedRequest = 0;

  @override
  void initState() {
    super.initState();
    final track = ref.read(currentTrackProvider);
    if (track != null) {
      _extractPalette(track);
      _checkIsLiked(track);
    }
  }

  Future<void> _checkIsLiked(SyncoraTrack track) async {
    _likedTrackId = track.id;
    final request = ++_likedRequest;
    final trackIdInt = int.tryParse(track.id) ?? track.id.hashCode.abs();
    final dao = ref.read(playlistDaoProvider);
    final liked = await dao.isTrackLiked(trackIdInt);
    if (!mounted || _likedTrackId != track.id || _likedRequest != request) return;
    setState(() => _isLiked = liked);
  }

  Future<void> _extractPalette(SyncoraTrack track) async {
    _paletteTrackId = track.id;
    if (track.coverUrl.isEmpty) {
      if (mounted) setState(() => _dominantColor = null);
      return;
    }

    try {
      final palette = await PaletteGenerator.fromImageProvider(
        // Reusa la copia ya cacheada en disco en vez de descargar la portada
        // una segunda vez solo para sacarle el color.
        CachedNetworkImageProvider(track.coverUrl),
        maximumColorCount: 8,
      );
      if (!mounted || _paletteTrackId != track.id) return;
      setState(() => _dominantColor = palette.dominantColor?.color);
    } catch (_) {
      if (!mounted || _paletteTrackId != track.id) return;
      setState(() => _dominantColor = null);
    }
  }

  Future<void> _toggleLike(SyncoraTrack track) async {
    // Antes esto solo escribía en Drift: el "me gusta" nunca subía a Supabase
    // y el siguiente sync lo podaba. Ver `toggleTrackLike`.
    final result = await toggleTrackLike(ref, track);

    if (mounted) {
      // Invalida cualquier consulta de "me gusta" en vuelo para esta misma
      // pista: el valor recién escrito es más nuevo que el que devuelva ella.
      _likedRequest++;
      _likedTrackId = track.id;
      setState(() => _isLiked = result.isLiked);
      if (result.remoteFailed) {
        AppToast.show(context, message: 'La playlist ya no existe en la nube');
      }
      AppToast.show(
        context,
        message: result.isLiked ? 'Se agregó a Tus me gusta.' : 'Se eliminó de Tus me gusta.',
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
    // H-R3-4: recalcular color de fondo y estado de "me gusta" en cada cambio
    // de pista, no solo al abrir la pantalla.
    ref.listen<SyncoraTrack?>(currentTrackProvider, (previous, next) {
      if (next == null || previous?.id == next.id) return;
      _extractPalette(next);
      _checkIsLiked(next);
    });

    final currentTrack = ref.watch(currentTrackProvider);
    final isPlaying = ref.watch(isPlayingProvider);
    final isShuffle = ref.watch(playerStateProvider.select((s) => s.isShuffle));
    final repeatMode = ref.watch(playerStateProvider.select((s) => s.repeatMode));
    final isLoading = ref.watch(playerStateProvider.select((s) =>
        s.engine.processingState == AudioProcessingState.loading ||
        s.engine.processingState == AudioProcessingState.buffering));
    final controller = ref.watch(syncoraPlayerControllerProvider.notifier);
    final canEdit = ref.watch(canEditProvider);

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
      // El reproductor a pantalla completa tapa el shell: los avisos van
      // pegados al borde inferior, no flotando sobre un mini reproductor que
      // aquí no se ve.
      body: BottomChromeScope(
        hasChrome: false,
        child: GestureDetector(
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
          duration: _dragOffsetY > 0 ? Duration.zero : const Duration(milliseconds: 200),
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
                  // Portada mas grande y repartida 1:1 (antes 3:1 hacia arriba,
                  // que dejaba un hueco muerto entre el header y la portada).
                  final coverSize = (availableHeight * 0.42).clamp(200.0, 360.0);

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
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

                          const Spacer(flex: 1),

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
                                      ? TrackCoverImage(
                                          coverUrl: currentTrack.coverUrl,
                                          trackId: int.tryParse(currentTrack.id),
                                          preferredSize: 1000,
                                          memCacheWidth: 1000,
                                          placeholder: _buildCoverPlaceholder(),
                                        )
                                      : _buildCoverPlaceholder(),
                                ),
                              ),
                            ),
                          ),

                          const Spacer(flex: 1),

                          // Sección inferior compacta
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
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
                                                fontWeight: FontWeight.w800,
                                                color: AppTheme.primary,
                                                fontSize: 22,
                                                letterSpacing: -0.5,
                                              ) ?? const TextStyle(
                                                fontSize: 22,
                                                fontWeight: FontWeight.w800,
                                                color: AppTheme.primary,
                                                letterSpacing: -0.5,
                                              ),
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
                                      // "Me gusta" escribe en Supabase: sin
                                      // conexión (y sin modo local) se apaga,
                                      // mismo patrón que el resto de la app.
                                      color: !canEdit
                                          ? AppTheme.muted
                                          : (_isLiked ? Colors.white : AppTheme.secondary),
                                      size: 28,
                                    ),
                                    tooltip: canEdit ? 'Me gusta' : 'Sin conexión',
                                    onPressed: canEdit ? () => _toggleLike(currentTrack) : null,
                                  ),
                                ],
                              ),

                              const SizedBox(height: 20),

                              // Barra de reproducción interactiva
                              _FullscreenSeekBar(
                                fallbackDuration: currentTrack.duration,
                                track: currentTrack,
                                controller: controller,
                                isPlaying: isPlaying,
                              ),

                              const SizedBox(height: 28),

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
                                            isShuffle ? AppIcons.outline(SolarIcons.Shuffle) : AppIcons.broken(SolarIcons.Shuffle),
                                            color: isShuffle ? Colors.white : AppTheme.secondary,
                                            size: 24,
                                          ),
                                          const SizedBox(height: 2),
                                          Container(
                                            width: 4,
                                            height: 4,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: isShuffle ? Colors.white : Colors.transparent,
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
                                        icon: isLoading
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
                                      final isRepeatActive = repeatMode != SyncoraRepeatMode.off;
                                      final repeatIconData = repeatMode == SyncoraRepeatMode.one
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

                              const SizedBox(height: 20),

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
                        ],
                      ),
                    );
                  },
                ),
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


  /// Ronda 3 (E2): antes este menú tenía solo dos opciones ("reproducir a
  /// continuación" y "agregar a la cola"), mientras que el mismo botón de 3
  /// puntos en cualquier lista ofrecía ocho. Ahora reusa la hoja compartida
  /// de `TrackContextMenu`, con las dos entradas propias del reproductor
  /// (encolar a continuación / al final) delante — así no pueden divergir.
  void _showTrackOptionsMenu(BuildContext context, SyncoraTrack track) {
    TrackContextMenu.showOptionsSheet(
      context,
      ref,
      track,
      onAddToQueue: () =>
          ref.read(syncoraPlayerControllerProvider.notifier).addToQueue(track),
      // Ronda 3 bis: ir al artista/álbum desde aquí dejaba el reproductor a
      // pantalla completa debajo en la pila, y como esas pantallas viven
      // dentro del shell, el shell acababa apilado dos veces. Cerrarlo antes
      // deja una pila coherente, y además es lo que espera el usuario:
      // navegar a la ficha del artista no es "abrir algo encima del
      // reproductor", es salir de él.
      onNavigateAway: () {
        if (context.mounted && Navigator.of(context).canPop()) context.pop();
      },
    );
  }
}

class _FullscreenSeekBar extends ConsumerStatefulWidget {
  final Duration? fallbackDuration;
  final SyncoraTrack track;
  final SyncoraPlayerController controller;
  final bool isPlaying;

  const _FullscreenSeekBar({
    this.fallbackDuration,
    required this.track,
    required this.controller,
    required this.isPlaying,
  });

  @override
  ConsumerState<_FullscreenSeekBar> createState() => _FullscreenSeekBarState();
}

class _FullscreenSeekBarState extends ConsumerState<_FullscreenSeekBar> {
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
    final position = ref.watch(playerStateProvider.select((s) => s.engine.position));
    final engineDuration = ref.watch(playerStateProvider.select((s) => s.engine.duration));
    final duration = engineDuration.inSeconds > 0
        ? engineDuration
        : (widget.fallbackDuration != null && widget.fallbackDuration!.inSeconds > 0
            ? widget.fallbackDuration!
            : const Duration(seconds: 180));

    final durationMs = duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 180000.0;
    final currentMs = position.inMilliseconds.toDouble().clamp(0.0, durationMs);
    final realRatio = (currentMs / durationMs).clamp(0.0, 1.0);
    final effectiveRatio = _isDragging ? _dragRatio : realRatio;

    final currentDisplayDuration = _isDragging
        ? Duration(milliseconds: (_dragRatio * durationMs).toInt())
        : position;

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
                _formatDuration(duration),
                style: const TextStyle(color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

