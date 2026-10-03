import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/cache/app_image_cache.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/connectivity_service.dart';
import '../../core/widgets/app_toast.dart';
import '../../core/widgets/error_state.dart';
import '../../core/widgets/skeleton_box.dart';
import '../../core/widgets/track_tile.dart';
import '../../data/local_db/database_provider.dart';
import '../../data/models/deezer/deezer_track.dart';
import '../library/services/like_track_service.dart';
import '../player/player_providers.dart';
import 'discover_feed.dart';
import '../../core/limits/app_limits.dart';

/// Descubrir (Fase 8.F): una canción por tarjeta, sonando 30 s sola.
///
/// En móvil se desliza hacia arriba para pasar a la siguiente; en PC hay
/// botones y teclado (↓/→ siguiente, ↑/← anterior, espacio pausa).
class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  final PageController _page = PageController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _page.dispose();
    _focus.dispose();
    super.dispose();
  }

  DiscoverFeed get _feed => ref.read(discoverFeedProvider.notifier);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowRight) {
      _feed.next();
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft) {
      _feed.previous();
    } else if (key == LogicalKeyboardKey.space) {
      _feed.togglePlay();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.sizeOf(context).width >= 768;
    final state = ref.watch(discoverFeedProvider);
    final isConnected = ref.watch(isConnectedProvider).value ?? true;

    // Cuando el feed avanza solo (fin de la preview) o con los botones, la
    // tarjeta visible lo sigue.
    ref.listen<int>(discoverFeedProvider.select((s) => s.index), (prev, next) {
      if (_page.hasClients && (_page.page?.round() ?? 0) != next) {
        _page.animateToPage(
          next,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    });

    final Widget body;
    if (!isConnected && state.tracks.isEmpty) {
      body = ErrorStateWidget(
        icon: AppIcons.broken(SolarIcons.WiFiRouterMinimalistic),
        title: 'Sin conexión',
        message: 'Descubrir escucha previews de Deezer: necesita internet.',
        retryLabel: 'Reintentar',
        onRetry: _feed.retry,
      );
    } else if (state.loading) {
      body = const _CardSkeleton();
    } else if (state.error != null && state.tracks.isEmpty) {
      body = ErrorStateWidget(
        title: 'No se pudo cargar Descubrir',
        message: state.error!,
        retryLabel: 'Reintentar',
        onRetry: _feed.retry,
      );
    } else if (state.tracks.isEmpty) {
      body = const _EmptyFeed();
    } else {
      final extra = state.exhausted ? 1 : (state.loadingMore ? 1 : 0);
      body = PageView.builder(
        controller: _page,
        scrollDirection: Axis.vertical,
        // En PC la rueda del ratón no encaja bien con un PageView: se pasa
        // con botones y teclado.
        physics: isDesktop
            ? const NeverScrollableScrollPhysics()
            : const PageScrollPhysics(),
        itemCount: state.tracks.length + extra,
        onPageChanged: _feed.setIndex,
        itemBuilder: (ctx, i) {
          if (i >= state.tracks.length) {
            return state.exhausted
                ? const _EmptyFeed(endOfFeed: true)
                : const _CardSkeleton();
          }
          return _DiscoverCard(
            track: state.tracks[i],
            isCurrent: i == state.index,
            isDesktop: isDesktop,
            remaining: state.tracks.length - state.index - 1,
          );
        },
      );
    }

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                isDesktop ? 24 : 8,
                isDesktop ? 16 : 8,
                isDesktop ? 24 : 16,
                4,
              ),
              child: Row(
                children: [
                  if (context.canPop())
                    IconButton(
                      tooltip: 'Atrás',
                      icon: Icon(
                        AppIcons.broken(SolarIcons.AltArrowLeft),
                        color: AppTheme.primary,
                      ),
                      onPressed: () => context.pop(),
                    ),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Descubrir',
                          style: TextStyle(
                            color: AppTheme.primary,
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.6,
                          ),
                        ),
                        Text(
                          'Canciones nuevas en 30 segundos',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppTheme.secondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isDesktop && state.tracks.isNotEmpty) ...[
                    IconButton(
                      tooltip: 'Anterior (↑)',
                      icon: Icon(
                        AppIcons.broken(SolarIcons.AltArrowUp),
                        color: AppTheme.primary,
                      ),
                      onPressed: state.index > 0 ? _feed.previous : null,
                    ),
                    IconButton(
                      tooltip: 'Siguiente (↓)',
                      icon: Icon(
                        AppIcons.broken(SolarIcons.AltArrowDown),
                        color: AppTheme.primary,
                      ),
                      onPressed: state.index < state.tracks.length - 1
                          ? _feed.next
                          : null,
                    ),
                  ],
                ],
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

class _DiscoverCard extends ConsumerWidget {
  const _DiscoverCard({
    required this.track,
    required this.isCurrent,
    required this.isDesktop,
    required this.remaining,
  });

  final DeezerTrack track;
  final bool isCurrent;
  final bool isDesktop;
  final int remaining;

  Future<void> _like(BuildContext context, WidgetRef ref) async {
    final result = await toggleTrackLike(ref, track.toSyncoraTrack());
    if (!context.mounted) return;
    AppToast.show(
      context,
      message: result.limitReached
          ? AppLimits.playlistFullMessage
          : result.remoteFailed
          ? 'No se pudo guardar. Revisa tu conexión.'
          : (result.isLiked
                ? 'Agregada a Tus me gusta'
                : 'Quitada de Tus me gusta'),
    );
  }

  Future<void> _playFull(WidgetRef ref) async {
    final feed = ref.read(discoverFeedProvider.notifier);
    final state = ref.read(discoverFeedProvider);
    await feed.stopPreview();
    // La canción completa y, detrás, el resto del feed: así se puede seguir
    // escuchando lo descubierto sin volver a esta pantalla.
    final from = state.tracks.indexWhere((t) => t.id == track.id);
    final queue = state.tracks
        .skip(from < 0 ? 0 : from)
        .map((t) => t.toSyncoraTrack())
        .toList();
    await ref
        .read(syncoraPlayerControllerProvider)
        .setQueue(queue, activeContextId: 'discover');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLiked = ref.watch(
      likedTrackIdsProvider.select((s) => s.value?.contains(track.id) ?? false),
    );
    final playing =
        isCurrent && ref.watch(discoverFeedProvider.select((s) => s.playing));
    final progress = isCurrent
        ? ref.watch(
            discoverFeedProvider.select((s) {
              final total = s.duration.inMilliseconds > 0
                  ? s.duration.inMilliseconds
                  : 30000;
              return (s.position.inMilliseconds / total).clamp(0.0, 1.0);
            }),
          )
        : 0.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final coverSize = (constraints.maxWidth - 48)
            .clamp(160.0, isDesktop ? 400.0 : 420.0)
            .clamp(160.0, constraints.maxHeight * 0.52);
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: isCurrent
                        ? ref.read(discoverFeedProvider.notifier).togglePlay
                        : null,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: coverSize,
                          height: coverSize,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: AppTheme.glowShadow,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: track.coverUrl.isEmpty
                                ? const _CoverPlaceholder()
                                : CachedNetworkImage(
                                    cacheManager: AppImageCache.instance,
                                    imageUrl: track.coverUrl,
                                    memCacheWidth: 600,
                                    fit: BoxFit.cover,
                                    errorWidget: (_, _, _) =>
                                        const _CoverPlaceholder(),
                                  ),
                          ),
                        ),
                        AnimatedOpacity(
                          opacity: isCurrent && !playing ? 1 : 0,
                          duration: const Duration(milliseconds: 150),
                          child: Container(
                            width: 64,
                            height: 64,
                            decoration: const BoxDecoration(
                              color: AppTheme.primary,
                              shape: BoxShape.circle,
                              boxShadow: AppTheme.glowShadow,
                            ),
                            child: Icon(
                              AppIcons.bold(SolarIcons.Play),
                              color: AppTheme.background,
                              size: 28,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: coverSize,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor: AppTheme.surfaceActive,
                        valueColor: const AlwaysStoppedAnimation(
                          AppTheme.primary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    track.title,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.primary,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: track.artistId > 0
                        ? () => context.push('/artist/${track.artistId}')
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Text(
                        track.artistName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.secondary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  if (track.albumTitle.isNotEmpty)
                    Text(
                      track.albumTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.muted,
                        fontSize: 12,
                      ),
                    ),
                  const SizedBox(height: 20),
                  // Cada botón ocupa una cuarta parte: en móviles angostos la
                  // fila se desbordaba con anchos naturales.
                  Row(
                    children: [
                      _ActionButton(
                        icon: isLiked
                            ? AppIcons.bold(SolarIcons.Heart)
                            : AppIcons.broken(SolarIcons.Heart),
                        label: isLiked ? 'Te gusta' : 'Me gusta',
                        onTap: () => _like(context, ref),
                      ),
                      _ActionButton(
                        icon: AppIcons.broken(SolarIcons.AddSquare),
                        label: 'A playlist',
                        onTap: () => TrackContextMenu.showAddToPlaylistDialog(
                          context,
                          ref,
                          track.toSyncoraTrack(),
                        ),
                      ),
                      _ActionButton(
                        icon: AppIcons.broken(SolarIcons.ListArrowDown),
                        label: 'A la cola',
                        onTap: () {
                          ref
                              .read(syncoraPlayerControllerProvider)
                              .addToQueue(track.toSyncoraTrack());
                          AppToast.show(context, message: 'Agregada a la cola');
                        },
                      ),
                      _ActionButton(
                        icon: AppIcons.broken(SolarIcons.PlayCircle),
                        label: 'Completa',
                        onTap: () => _playFull(ref),
                      ),
                    ],
                  ),
                  if (!isDesktop && isCurrent && remaining > 0) ...[
                    const SizedBox(height: 18),
                    Icon(
                      AppIcons.broken(SolarIcons.AltArrowUp),
                      color: AppTheme.muted,
                      size: 18,
                    ),
                    const Text(
                      'Desliza para la siguiente',
                      style: TextStyle(color: AppTheme.muted, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: AppTheme.primary, size: 24),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.secondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CardSkeleton extends StatelessWidget {
  const _CardSkeleton();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final size = (c.maxWidth - 48)
            .clamp(160.0, 400.0)
            .clamp(160.0, c.maxHeight * 0.52);
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SkeletonBox(width: size, height: size, borderRadius: 16),
              const SizedBox(height: 20),
              const SkeletonBox(width: 220, height: 22, borderRadius: 6),
              const SizedBox(height: 10),
              const SkeletonBox(width: 140, height: 14, borderRadius: 6),
            ],
          ),
        );
      },
    );
  }
}

class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed({this.endOfFeed = false});

  final bool endOfFeed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.broken(SolarIcons.CompassBig),
              color: AppTheme.secondary,
              size: 56,
            ),
            const SizedBox(height: 16),
            Text(
              endOfFeed ? 'Eso es todo por ahora' : 'Nada nuevo que mostrar',
              style: const TextStyle(
                color: AppTheme.primary,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Escucha más música y vuelve: Descubrir se arma con artistas parecidos a los que más escuchas.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.secondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.surfaceHover,
      child: Icon(
        AppIcons.broken(SolarIcons.MusicNotes),
        color: AppTheme.muted,
        size: 48,
      ),
    );
  }
}
