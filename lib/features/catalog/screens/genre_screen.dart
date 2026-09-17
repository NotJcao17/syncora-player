import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/playlist_card.dart';
import '../../../core/widgets/skeleton_box.dart';
import '../../../core/widgets/track_tile.dart';
import '../../../data/apis/deezer_catalog_providers.dart';
import '../../../data/models/deezer/deezer_genre.dart';
import '../../player/player_providers.dart';
import '../../player/radio/radio_service.dart';

/// Pantalla de un género (`/genre/:id`).
///
/// Todo el contenido principal sale de **una sola petición**: `/chart/{genre_id}`
/// devuelve pistas, álbumes, artistas y playlists del género de una vez. Las
/// radios son una segunda petición, cacheada una semana.
///
/// Reemplaza el comportamiento anterior de los botones de género de Búsqueda,
/// que se limitaban a escribir la palabra en el buscador ("Pop" buscaba el
/// texto "pop", con los resultados que eso implica).
class GenreScreen extends ConsumerWidget {
  final String genreId;
  final String? genreName;

  const GenreScreen({super.key, required this.genreId, this.genreName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = int.tryParse(genreId) ?? 0;
    if (id <= 0) {
      return const Scaffold(
        backgroundColor: AppTheme.background,
        body: ErrorStateWidget(message: 'Género no válido'),
      );
    }

    final isDesktop = MediaQuery.of(context).size.width >= 768;
    final chartAsync = ref.watch(deezerGenreChartProvider(id));
    final radiosAsync = ref.watch(deezerGenreRadiosProvider(id));

    // El nombre llega por la navegación para poder pintar la cabecera sin
    // esperar a la red; si no vino (enlace directo), se busca en el catálogo.
    final resolvedName = genreName ??
        ref.watch(deezerGenresProvider).value?.where((g) => g.id == id).firstOrNull?.name ??
        'Género';
    final headerImage =
        ref.watch(deezerGenresProvider).value?.where((g) => g.id == id).firstOrNull?.pictureUrl ?? '';

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(deezerGenreChartProvider(id));
            ref.invalidate(deezerGenreRadiosProvider(id));
          },
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: _GenreHeader(
                  name: resolvedName,
                  imageUrl: headerImage,
                  isDesktop: isDesktop,
                ),
              ),
              ...chartAsync.when(
                loading: () => [
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
                    sliver: const SliverToBoxAdapter(
                      child: Column(
                        children: [
                          SkeletonBox(height: 200, borderRadius: 16),
                          SizedBox(height: 16),
                          SkeletonBox(height: 200, borderRadius: 16),
                        ],
                      ),
                    ),
                  ),
                ],
                error: (e, _) => [
                  SliverToBoxAdapter(
                    child: ErrorStateWidget(
                      message: 'No pudimos cargar $resolvedName',
                      onRetry: () => ref.invalidate(deezerGenreChartProvider(id)),
                    ),
                  ),
                ],
                data: (chart) {
                  if (chart.isEmpty) {
                    return [
                      SliverToBoxAdapter(
                        child: ErrorStateWidget(
                          message: 'Deezer no tiene contenido para $resolvedName ahora mismo',
                          onRetry: () => ref.invalidate(deezerGenreChartProvider(id)),
                        ),
                      ),
                    ];
                  }

                  final topTracks = chart.tracks.take(10).map((t) => t.toSyncoraTrack()).toList();
                  final allTracks = chart.tracks.map((t) => t.toSyncoraTrack()).toList();
                  final contextId = 'genre_$id';

                  return [
                    if (topTracks.isNotEmpty) ...[
                      _sectionTitle(context, 'Top de $resolvedName', isDesktop,
                          trailing: _PlayAllButton(
                            onPressed: () {
                              final controller = ref.read(syncoraPlayerControllerProvider.notifier);
                              final isShuffle = ref.read(playerStateProvider).isShuffle;
                              controller.setQueue(
                                allTracks,
                                startIndex: isShuffle
                                    ? RadioService.pickShuffledStartIndex(allTracks.length, math.Random())
                                    : 0,
                                activeContextId: contextId,
                              );
                              controller.play();
                            },
                          )),
                      SliverPadding(
                        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 24 : 8),
                        sliver: SliverList.builder(
                          itemCount: topTracks.length,
                          itemBuilder: (ctx, i) {
                            final track = topTracks[i];
                            return Consumer(
                              builder: (context, ref, _) {
                                final current = ref.watch(currentTrackProvider);
                                return TrackTile(
                                  track: track,
                                  index: i,
                                  isPlaying: current?.id == track.id,
                                  onTap: () => ref
                                      .read(syncoraPlayerControllerProvider.notifier)
                                      .setQueue(allTracks, startIndex: i, activeContextId: contextId),
                                  onAddToQueue: () => ref
                                      .read(syncoraPlayerControllerProvider.notifier)
                                      .addToQueue(track),
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ],
                    if (chart.artists.isNotEmpty) ...[
                      _sectionTitle(context, 'Artistas de $resolvedName', isDesktop),
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: isDesktop ? 190 : 160,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
                            itemCount: chart.artists.length,
                            separatorBuilder: (_, _) => const SizedBox(width: 16),
                            itemBuilder: (ctx, i) {
                              final artist = chart.artists[i];
                              return _ArtistCircle(
                                name: artist.name,
                                pictureUrl: artist.pictureUrl,
                                size: isDesktop ? 130 : 110,
                                onTap: () => context.push('/artist/${artist.id}'),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                    if (chart.playlists.isNotEmpty) ...[
                      _sectionTitle(context, 'Playlists de $resolvedName', isDesktop),
                      _horizontalCards(
                        isDesktop: isDesktop,
                        itemCount: chart.playlists.length,
                        builder: (i) {
                          final playlist = chart.playlists[i];
                          return PlaylistCard(
                            title: playlist.title,
                            subtitle: '${playlist.nbTracks} canciones • ${playlist.userName}',
                            coverUrl: playlist.pictureUrl,
                            onTap: () => context.push('/deezer-playlist/${playlist.id}'),
                          );
                        },
                      ),
                    ],
                    if (chart.albums.isNotEmpty) ...[
                      _sectionTitle(context, 'Álbumes de $resolvedName', isDesktop),
                      _horizontalCards(
                        isDesktop: isDesktop,
                        itemCount: chart.albums.length,
                        builder: (i) {
                          final album = chart.albums[i];
                          return PlaylistCard(
                            title: album.title,
                            subtitle: 'Álbum • ${album.artistName}',
                            coverUrl: album.coverUrl,
                            onTap: () => context.push('/album/${album.id}'),
                          );
                        },
                      ),
                    ],
                  ];
                },
              ),
              ...radiosAsync.maybeWhen(
                data: (radios) => radios.isEmpty
                    ? const <Widget>[]
                    : [
                        _sectionTitle(context, 'Radios de $resolvedName', isDesktop),
                        _horizontalCards(
                          isDesktop: isDesktop,
                          itemCount: radios.length,
                          builder: (i) => _RadioCard(radio: radios[i]),
                        ),
                      ],
                orElse: () => const <Widget>[],
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _sectionTitle(BuildContext context, String text, bool isDesktop, {Widget? trailing}) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(isDesktop ? 32 : 20, 28, isDesktop ? 32 : 20, 12),
      sliver: SliverToBoxAdapter(
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: AppTheme.primary,
                    ),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }

  static Widget _horizontalCards({
    required bool isDesktop,
    required int itemCount,
    required Widget Function(int index) builder,
  }) {
    return SliverToBoxAdapter(
      child: SizedBox(
        height: isDesktop ? 240 : 200,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
          itemCount: itemCount,
          separatorBuilder: (_, _) => const SizedBox(width: 16),
          itemBuilder: (ctx, i) => SizedBox(width: isDesktop ? 180 : 140, child: builder(i)),
        ),
      ),
    );
  }
}

class _GenreHeader extends StatelessWidget {
  final String name;
  final String imageUrl;
  final bool isDesktop;

  const _GenreHeader({required this.name, required this.imageUrl, required this.isDesktop});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: isDesktop ? 220 : 170,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (imageUrl.isNotEmpty)
            CachedNetworkImage(imageUrl: imageUrl, fit: BoxFit.cover)
          else
            Container(color: AppTheme.surfaceHover),
          // El degradado no es decorativo: las imágenes de género de Deezer son
          // collages claros y el título quedaba ilegible encima.
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.45),
                  Colors.black.withValues(alpha: 0.75),
                  AppTheme.background,
                ],
                stops: const [0.0, 0.6, 1.0],
              ),
            ),
          ),
          Positioned(
            left: isDesktop ? 32 : 20,
            right: isDesktop ? 32 : 20,
            bottom: 18,
            child: Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.primary,
                fontSize: isDesktop ? 44 : 32,
                fontWeight: FontWeight.w900,
                letterSpacing: -1,
              ),
            ),
          ),
          Positioned(
            top: 8,
            left: 12,
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
    );
  }
}

class _PlayAllButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _PlayAllButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(AppIcons.outline(SolarIcons.Play), size: 16, color: AppTheme.accent),
      label: const Text('Reproducir', style: TextStyle(color: AppTheme.accent, fontWeight: FontWeight.bold)),
    );
  }
}

class _ArtistCircle extends StatelessWidget {
  final String name;
  final String pictureUrl;
  final double size;
  final VoidCallback onTap;

  const _ArtistCircle({
    required this.name,
    required this.pictureUrl,
    required this.size,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(size),
      child: SizedBox(
        width: size,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipOval(
              child: SizedBox(
                width: size,
                height: size,
                child: pictureUrl.isEmpty
                    ? Container(color: AppTheme.surfaceHover)
                    : CachedNetworkImage(imageUrl: pictureUrl, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tarjeta de radio editorial: al tocarla, se reproduce directamente.
///
/// No abre una pantalla de detalle porque no habría nada estable que mostrar —
/// `/radio/{id}/tracks` devuelve una selección distinta en cada llamada.
class _RadioCard extends ConsumerStatefulWidget {
  final DeezerRadio radio;

  const _RadioCard({required this.radio});

  @override
  ConsumerState<_RadioCard> createState() => _RadioCardState();
}

class _RadioCardState extends ConsumerState<_RadioCard> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return PlaylistCard(
      title: widget.radio.title,
      subtitle: _isLoading ? 'Cargando…' : 'Radio',
      coverUrl: widget.radio.pictureUrl,
      onTap: _isLoading ? null : _playRadio,
    );
  }

  Future<void> _playRadio() async {
    setState(() => _isLoading = true);
    try {
      final tracks = await ref.read(deezerRadioTracksProvider(widget.radio.id).future);
      if (!mounted) return;
      if (tracks.isEmpty) {
        AppToast.show(context, message: 'Esta radio no devolvió canciones');
        return;
      }
      ref.read(syncoraPlayerControllerProvider.notifier).setQueue(
            tracks.map((t) => t.toSyncoraTrack()).toList(),
            startIndex: 0,
            activeContextId: 'radio_${widget.radio.id}',
          );
      ref.read(syncoraPlayerControllerProvider.notifier).play();
    } catch (_) {
      if (!mounted) return;
      AppToast.show(context, message: 'No se pudo iniciar la radio');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}
