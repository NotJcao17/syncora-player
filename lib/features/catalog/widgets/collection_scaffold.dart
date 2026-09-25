import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/cover_palette.dart';
import '../../../core/widgets/track_tile.dart';
import '../../download/widgets/download_header_button.dart';
import '../../player/audio_engine/audio_engine_state.dart';
import '../../player/player_models.dart';
import '../../player/player_providers.dart';
import '../../player/radio/radio_service.dart';
import '../../player/syncora_player_controller.dart';

/// Cabecera + lista de pistas comunes a las colecciones que **no** viven en la
/// biblioteca del usuario: playlists de Deezer, tops por país y mixes.
///
/// Se extrajo en vez de copiar `AlbumDetailScreen` por tercera vez: las tres
/// pantallas nuevas comparten exactamente el mismo esqueleto (degradado con el
/// color dominante de la portada, botones de reproducir/aleatorio/descargar,
/// cabecera de columnas en escritorio, `TrackTile` en móvil) y solo cambian el
/// título, la etiqueta y los botones propios de cada una.
///
/// Responsive por diseño: en escritorio, portada grande a la izquierda y datos
/// a la derecha con la tabla de columnas; en móvil, portada centrada, todo
/// apilado y sin tabla. Es el mismo corte de 768 px que usa el resto de la app.
class CollectionScaffold extends ConsumerStatefulWidget {
  /// Etiqueta pequeña sobre el título: PLAYLIST, MIX, TOP...
  final String label;
  final String title;
  final String subtitle;
  final String coverUrl;
  final List<SyncoraTrack> tracks;

  /// Identificador del contexto de reproducción, para que el reproductor sepa
  /// que la cola activa viene de esta colección.
  final String contextId;

  /// Botones propios de cada pantalla (guardar, regenerar...).
  final List<Widget> actions;

  final Future<void> Function()? onRefresh;

  /// Mensaje cuando la colección no tiene ninguna pista reproducible.
  final String emptyMessage;

  /// Portada a medida, para colecciones sin carátula propia (el mix
  /// "On Repeat" usa color + ícono, como "Tus me gusta").
  final Widget? coverOverride;

  /// Paso previo a descargar. Las colecciones que no están en la biblioteca lo
  /// usan para guardarse primero: así ninguna descarga queda colgando sin una
  /// colección a la que pertenezca.
  final Future<bool> Function()? onBeforeDownload;

  const CollectionScaffold({
    super.key,
    required this.label,
    required this.title,
    required this.subtitle,
    required this.coverUrl,
    required this.tracks,
    required this.contextId,
    this.actions = const [],
    this.onRefresh,
    this.emptyMessage = 'No hay canciones para mostrar.',
    this.coverOverride,
    this.onBeforeDownload,
  });

  @override
  ConsumerState<CollectionScaffold> createState() => _CollectionScaffoldState();
}

class _CollectionScaffoldState extends ConsumerState<CollectionScaffold> {
  Color? _dominantColor;
  String? _paletteSourceUrl;

  @override
  void initState() {
    super.initState();
    _extractPalette();
  }

  @override
  void didUpdateWidget(covariant CollectionScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    // La portada cambia cuando el contenido termina de cargar (o al regenerar
    // un mix). Sin esto, el degradado se quedaba con el color de la pantalla
    // anterior — el mismo bug que la ronda 3 encontró en el reproductor a
    // pantalla completa (H-R3-4), que solo calculaba la paleta en `initState`.
    if (oldWidget.coverUrl != widget.coverUrl) _extractPalette();
  }

  Future<void> _extractPalette() async {
    // Con portada generada no hay imagen de la que sacar color; el degradado
    // se queda con el tono neutro por defecto.
    if (widget.coverOverride != null) return;
    final url = widget.coverUrl;
    if (url.isEmpty || url == _paletteSourceUrl) return;
    _paletteSourceUrl = url;
    try {
      final palette = await CoverPalette.of(url);
      if (!mounted || palette == null) return;
      setState(() {
        _dominantColor = palette.vibrantColor?.color ??
            palette.dominantColor?.color ??
            palette.mutedColor?.color;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.sizeOf(context).width >= 768;
    final controller = ref.watch(syncoraPlayerControllerProvider.notifier);
    final currentTrack = ref.watch(currentTrackProvider);
    final isPlaying = ref.watch(isPlayingProvider);
    final tracks = widget.tracks;

    final isCurrentContext =
        ref.watch(playerStateProvider.select((s) => s.activeContextId == widget.contextId));
    final isBuffering = ref.watch(playerStateProvider.select((s) =>
        s.engine.processingState == AudioProcessingState.loading ||
        s.engine.processingState == AudioProcessingState.buffering));
    final showPause = isCurrentContext && (isPlaying || isBuffering);

    final gradientColor =
        _dominantColor?.withValues(alpha: 0.35) ?? AppTheme.surfaceHover.withValues(alpha: 0.3);

    final scroll = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(context).top + 56,
            left: isDesktop ? 32 : 12,
            right: isDesktop ? 32 : 12,
          ),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                if (isDesktop) _buildDesktopHeader() else _buildMobileHeader(),
                const SizedBox(height: 16),
                _buildActionBar(
                  isDesktop: isDesktop,
                  controller: controller,
                  showPause: showPause,
                  isCurrentContext: isCurrentContext,
                  isBuffering: isBuffering,
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
        if (tracks.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
              child: Text(
                widget.emptyMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.secondary, fontSize: 14),
              ),
            ),
          )
        else ...[
          if (isDesktop)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              sliver: const SliverToBoxAdapter(child: _DesktopColumnHeader()),
            ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 12),
            sliver: SliverList.builder(
              itemCount: tracks.length,
              itemBuilder: (ctx, i) {
                final track = tracks[i];
                return TrackTile(
                  track: track,
                  index: i,
                  isPlaying: currentTrack?.id == track.id,
                  showAlbum: true,
                  onTap: () => controller.setQueue(
                    tracks,
                    startIndex: i,
                    activeContextId: widget.contextId,
                  ),
                  onAddToQueue: () => controller.addToQueue(track),
                );
              },
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [gradientColor, AppTheme.background, AppTheme.background],
            stops: const [0.0, 0.45, 1.0],
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: widget.onRefresh == null
                  ? scroll
                  : RefreshIndicator(onRefresh: widget.onRefresh!, child: scroll),
            ),
            Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              left: 16,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.35),
                ),
                child: IconButton(
                  icon: Icon(AppIcons.broken(SolarIcons.AltArrowLeft), color: AppTheme.primary, size: 20),
                  onPressed: () => context.pop(),
                  padding: EdgeInsets.zero,
                  tooltip: 'Volver',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCover(double size, double radius) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: AppTheme.glowShadow,
          color: AppTheme.surfaceHover,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: widget.coverOverride ??
              (widget.coverUrl.isEmpty
                  ? Icon(AppIcons.broken(SolarIcons.MusicLibrary), color: AppTheme.secondary, size: size * 0.3)
                  : CachedNetworkImage(imageUrl: widget.coverUrl, fit: BoxFit.cover)),
        ),
      );

  Widget _buildDesktopHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _buildCover(220, 16),
        const SizedBox(width: 28),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.label.toUpperCase(),
                style: const TextStyle(
                  color: AppTheme.secondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.primary,
                  fontSize: 40,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                widget.subtitle,
                style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMobileHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Center(child: _buildCover(180, 20)),
        const SizedBox(height: 16),
        Text(
          widget.title,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppTheme.primary,
            fontSize: 26,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          widget.subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
        ),
      ],
    );
  }

  Widget _buildActionBar({
    required bool isDesktop,
    required SyncoraPlayerController controller,
    required bool showPause,
    required bool isCurrentContext,
    required bool isBuffering,
  }) {
    final tracks = widget.tracks;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisAlignment: isDesktop ? MainAxisAlignment.start : MainAxisAlignment.center,
        children: [
          if (tracks.isNotEmpty) ...[
            CollectionPlayButton(
              isPlaying: showPause,
              isLoading: isCurrentContext && isBuffering,
              onPressed: () {
                if (showPause) {
                  controller.pause();
                } else if (isCurrentContext) {
                  controller.play();
                } else {
                  final isShuffle = ref.read(playerStateProvider).isShuffle;
                  final startIndex = isShuffle
                      ? RadioService.pickShuffledStartIndex(tracks.length, math.Random())
                      : 0;
                  controller.setQueue(tracks, startIndex: startIndex, activeContextId: widget.contextId);
                  controller.play();
                }
              },
            ),
            const SizedBox(width: 12),
            DownloadHeaderButton(
              title: widget.title,
              tracks: tracks,
              onBeforeDownload: widget.onBeforeDownload,
            ),
            const SizedBox(width: 12),
            Consumer(
              builder: (context, ref, _) {
                final isShuffle = ref.watch(playerStateProvider.select((s) => s.isShuffle));
                return IconButton(
                  icon: Icon(
                    isShuffle ? AppIcons.outline(SolarIcons.Shuffle) : AppIcons.broken(SolarIcons.Shuffle),
                    color: isShuffle ? Colors.white : AppTheme.secondary,
                    size: 22,
                  ),
                  tooltip: 'Aleatorio',
                  onPressed: () {
                    if (isCurrentContext) {
                      controller.toggleShuffle();
                    } else {
                      controller.setQueue(tracks, startIndex: 0, activeContextId: widget.contextId);
                      if (!isShuffle) controller.toggleShuffle();
                      controller.play();
                    }
                  },
                );
              },
            ),
            const SizedBox(width: 8),
          ],
          ...widget.actions,
        ],
      ),
    );
  }
}

class _DesktopColumnHeader extends StatelessWidget {
  const _DesktopColumnHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const SizedBox(
                width: 28,
                child: Text(
                  '#',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.secondary, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                flex: 3,
                child: Padding(
                  padding: EdgeInsets.only(left: 60),
                  child: Text(
                    'TÍTULO',
                    style: TextStyle(
                      color: AppTheme.secondary,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              const Expanded(
                flex: 2,
                child: Text(
                  'ÁLBUM',
                  style: TextStyle(
                    color: AppTheme.secondary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 50,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Icon(AppIcons.broken(SolarIcons.ClockCircle), color: AppTheme.secondary, size: 16),
                ),
              ),
              const SizedBox(width: 52),
            ],
          ),
        ),
        const Divider(height: 12, color: AppTheme.surfaceHover),
      ],
    );
  }
}

/// Botón circular grande de reproducción con hover, igual al de la pantalla de
/// álbum (que lo tiene privado).
class CollectionPlayButton extends StatefulWidget {
  final bool isPlaying;
  final bool isLoading;
  final VoidCallback onPressed;

  const CollectionPlayButton({
    super.key,
    required this.isPlaying,
    this.isLoading = false,
    required this.onPressed,
  });

  @override
  State<CollectionPlayButton> createState() => _CollectionPlayButtonState();
}

class _CollectionPlayButtonState extends State<CollectionPlayButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _isHovered ? 1.08 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.primary,
              boxShadow: _isHovered ? AppTheme.glowHighShadow : AppTheme.glowShadow,
            ),
            child: Center(
              child: widget.isLoading
                  ? LoadingAnimationWidget.threeArchedCircle(color: AppTheme.background, size: 26)
                  : Icon(
                      widget.isPlaying ? AppIcons.broken(SolarIcons.Pause) : AppIcons.outline(SolarIcons.Play),
                      color: AppTheme.background,
                      size: 28,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
