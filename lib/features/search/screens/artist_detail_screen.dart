import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_icons.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/playlist_card.dart';
import '../../../core/widgets/track_tile.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/models/deezer/deezer_album.dart';
import '../../../data/models/deezer/deezer_artist.dart';
import '../../../data/models/deezer/deezer_track.dart';
import '../../player/player_providers.dart';

/// Pantalla de Detalle de Artista (`/artist/:id`) conectada a Deezer real.
class ArtistDetailScreen extends ConsumerStatefulWidget {
  final String artistId;

  const ArtistDetailScreen({
    super.key,
    required this.artistId,
  });

  @override
  ConsumerState<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends ConsumerState<ArtistDetailScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  DeezerArtist? _artist;
  List<DeezerTrack> _topTracks = [];
  List<DeezerAlbum> _albums = [];

  /// Ronda 3 (F2): `/artist/{id}/top` sin `limit` devuelve 5 resultados, no
  /// 10. Se piden [_topTracksFetched] de una vez y se muestran
  /// [_topTracksCollapsed]; "Mostrar más" revela el resto **sin una segunda
  /// petición**, que es la razón de pedir de más desde el principio.
  static const int _topTracksFetched = 10;
  static const int _topTracksCollapsed = 5;
  bool _showAllTopTracks = false;

  /// Ronda 3 (F1): filtro de discografía. Deezer ya manda `record_type` en
  /// `/artist/{id}/albums`, así que separar álbumes de sencillos no cuesta
  /// ninguna petición extra.
  _DiscographyFilter _discographyFilter = _DiscographyFilter.todo;

  List<DeezerAlbum> get _filteredAlbums {
    switch (_discographyFilter) {
      case _DiscographyFilter.todo:
        return _albums;
      case _DiscographyFilter.albumes:
        return _albums.where((a) => a.isFullAlbum).toList();
      case _DiscographyFilter.sencillos:
        return _albums.where((a) => a.recordType == 'single').toList();
      case _DiscographyFilter.eps:
        return _albums.where((a) => a.recordType == 'ep').toList();
    }
  }

  /// ¿Vale la pena pintar las píldoras? Si el artista no tiene de los dos
  /// tipos, un filtro con una sola opción útil es ruido.
  bool get _showDiscographyFilter =>
      _albums.any((a) => a.isSingleOrEp) && _albums.any((a) => a.isFullAlbum);

  /// Píldoras visibles: se omite la de un tipo que este artista no tiene
  /// (muchos artistas no publican EPs, y una píldora que siempre da vacío es
  /// ruido).
  List<_DiscographyFilter> get _visibleDiscographyFilters => _DiscographyFilter.values
      .where((f) =>
          f == _DiscographyFilter.todo ||
          (f == _DiscographyFilter.albumes && _albums.any((a) => a.isFullAlbum)) ||
          (f == _DiscographyFilter.sencillos && _albums.any((a) => a.recordType == 'single')) ||
          (f == _DiscographyFilter.eps && _albums.any((a) => a.recordType == 'ep')))
      .toList();

  @override
  void initState() {
    super.initState();
    _loadArtistData();
  }

  Future<void> _loadArtistData() async {
    setState(() {
      if (_artist == null) {
        _isLoading = true;
      }
      _errorMessage = null;
    });

    final id = int.tryParse(widget.artistId) ?? 0;
    if (id == 0) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'ID de artista inválido';
      });
      return;
    }

    try {
      final api = ref.read(deezerApiProvider);
      final results = await Future.wait([
        api.getArtist(id),
        api.getArtistTopTracks(id, limit: _topTracksFetched),
        api.getArtistAlbums(id),
      ]);

      if (mounted) {
        final rawAlbums = results[2] as List<DeezerAlbum>;
        rawAlbums.sort((a, b) {
          if (a.releaseDate.isEmpty) return 1;
          if (b.releaseDate.isEmpty) return -1;
          return b.releaseDate.compareTo(a.releaseDate);
        });

        setState(() {
          _artist = results[0] as DeezerArtist;
          _topTracks = results[1] as List<DeezerTrack>;
          _albums = rawAlbums;
          _isLoading = false;
          _showAllTopTracks = false;
          if (_discographyFilter != _DiscographyFilter.todo && _filteredAlbums.isEmpty) {
            // El artista recargado no tiene nada del tipo filtrado: no dejar
            // la pantalla vacía por un filtro que ya no aplica.
            _discographyFilter = _DiscographyFilter.todo;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Error al cargar los datos del artista.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(syncoraPlayerControllerProvider.notifier);
    final currentTrack = ref.watch(currentTrackProvider);
    final isDesktop = MediaQuery.of(context).size.width >= 768;

    if (_isLoading) {
      return const Scaffold(
        backgroundColor: AppTheme.background,
        body: Center(child: CircularProgressIndicator(color: AppTheme.primary)),
      );
    }

    if (_errorMessage != null || _artist == null) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        body: ErrorStateWidget(
          message: _errorMessage ?? 'No se encontró el artista',
          onRetry: _loadArtistData,
        ),
      );
    }

    final artist = _artist!;
    final syncoraTracks = _topTracks.map((t) => t.toSyncoraTrack()).toList();
    final visibleTopTracks = _showAllTopTracks
        ? syncoraTracks.length
        : (syncoraTracks.length < _topTracksCollapsed
            ? syncoraTracks.length
            : _topTracksCollapsed);
    final visibleAlbums = _filteredAlbums;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: RefreshIndicator(
        onRefresh: _loadArtistData,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // Header con foto del artista
            SliverAppBar(
              backgroundColor: AppTheme.surface,
              expandedHeight: isDesktop ? 340 : 280,
              pinned: true,
              leading: Padding(
                padding: const EdgeInsets.all(8.0),
                child: CircleAvatar(
                  backgroundColor: AppTheme.surfaceHover,
                  child: IconButton(
                    icon: Icon(AppIcons.broken(SolarIcons.AltArrowLeft), color: AppTheme.primary, size: 20),
                    onPressed: () => context.pop(),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
              flexibleSpace: FlexibleSpaceBar(
                background: Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedNetworkImage(
                      imageUrl: artist.pictureUrl,
                      memCacheWidth: 600,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => Container(color: AppTheme.surface),
                    ),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            AppTheme.background.withValues(alpha: 0.7),
                            AppTheme.background,
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 20,
                      left: isDesktop ? 32 : 20,
                      right: isDesktop ? 32 : 20,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(AppIcons.broken(SolarIcons.CheckCircle), color: AppTheme.primary, size: 16),
                              SizedBox(width: 6),
                              Text(
                                'ARTISTA VERIFICADO',
                                style: TextStyle(
                                  color: AppTheme.primary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            artist.name,
                            style: TextStyle(
                              color: AppTheme.primary,
                              fontSize: isDesktop ? 44 : 32,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${artist.nbFan} fans en Deezer',
                            style: const TextStyle(color: AppTheme.secondary, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Botón Reproducir
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: isDesktop ? 32 : 20,
                  vertical: 16,
                ),
                child: Row(
                  children: [
                    if (syncoraTracks.isNotEmpty)
                      _HeaderPlayButton(
                        onPressed: () {
                          controller.setQueue(syncoraTracks, startIndex: 0);
                          controller.play();
                        },
                      ),
                    if (isDesktop) ...[
                      const SizedBox(width: 16),
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        color: AppTheme.primary,
                        tooltip: 'Actualizar discografía',
                        onPressed: _loadArtistData,
                      ),
                    ],
                  ],
                ),
              ),
            ),

          // Top Canciones
          SliverPadding(
            padding: EdgeInsets.symmetric(
              horizontal: isDesktop ? 32 : 20,
              vertical: 12,
            ),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Canciones populares',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ),

          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) {
                  final track = syncoraTracks[i];
                  return TrackTile(
                    track: track,
                    index: i,
                    isPlaying: currentTrack?.id == track.id,
                    onTap: () {
                      // La cola se arma SIEMPRE con el top completo, se estén
                      // mostrando 5 o 10: colapsar la lista es una decisión
                      // visual, no debe recortar lo que suena después.
                      controller.setQueue(syncoraTracks, startIndex: i);
                    },
                    onAddToQueue: () => controller.addToQueue(track),
                  );
                },
                childCount: visibleTopTracks,
              ),
            ),
          ),

          if (syncoraTracks.length > _topTracksCollapsed)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(isDesktop ? 32 : 20, 4, isDesktop ? 32 : 20, 0),
              sliver: SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => setState(() => _showAllTopTracks = !_showAllTopTracks),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      minimumSize: const Size(0, 40),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      _showAllTopTracks ? 'Mostrar menos' : 'Mostrar más',
                      style: const TextStyle(
                        color: AppTheme.secondary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Discografía
          if (visibleAlbums.isNotEmpty)
            SliverPadding(
              padding: EdgeInsets.symmetric(
                horizontal: isDesktop ? 32 : 20,
                vertical: 20,
              ),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Discografía',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    if (_showDiscographyFilter) ...[
                      const SizedBox(height: 12),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: _visibleDiscographyFilters.map((f) {
                            final selected = _discographyFilter == f;
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(f.label),
                                selected: selected,
                                onSelected: (val) {
                                  if (val) setState(() => _discographyFilter = f);
                                },
                                selectedColor: AppTheme.primary,
                                backgroundColor: AppTheme.surface,
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                labelStyle: TextStyle(
                                  color: selected ? AppTheme.background : AppTheme.primary,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12,
                                ),
                                shape: StadiumBorder(
                                  side: BorderSide(
                                    color: selected ? AppTheme.primary : AppTheme.surfaceHover,
                                  ),
                                ),
                                showCheckmark: false,
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 220,
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(context).copyWith(
                          dragDevices: {
                            PointerDeviceKind.touch,
                            PointerDeviceKind.mouse,
                            PointerDeviceKind.trackpad,
                            PointerDeviceKind.stylus,
                          },
                        ),
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: visibleAlbums.length,
                          separatorBuilder: (ctx, index) => const SizedBox(width: 16),
                          itemBuilder: (ctx, i) {
                            final album = visibleAlbums[i];
                            final year = album.releaseDate.length >= 4
                                ? album.releaseDate.substring(0, 4)
                                : '';
                            // Con el filtro visible, el tipo de lanzamiento es
                            // la información que ayuda a distinguirlos.
                            final tipo = album.isSingleOrEp
                                ? (album.recordType == 'ep' ? 'EP' : 'Sencillo')
                                : 'Álbum';
                            final subtitleText = year.isNotEmpty ? '$tipo • $year' : tipo;
                            return SizedBox(
                              width: isDesktop ? 192 : 144,
                              child: PlaylistCard(
                                title: album.title,
                                subtitle: subtitleText,
                                coverUrl: album.coverUrl,
                                onTap: () => context.push('/album/${album.id}'),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    ),
  );
  }
}

class _HeaderPlayButton extends StatefulWidget {
  final VoidCallback onPressed;

  const _HeaderPlayButton({required this.onPressed});

  @override
  State<_HeaderPlayButton> createState() => _HeaderPlayButtonState();
}

class _HeaderPlayButtonState extends State<_HeaderPlayButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
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
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: IconButton(
              style: IconButton.styleFrom(
                shape: const CircleBorder(),
                padding: EdgeInsets.zero,
              ),
              icon: Icon(AppIcons.outline(SolarIcons.Play), color: AppTheme.background, size: 26),
              onPressed: widget.onPressed,
            ),
          ),
        ),
      ),
    );
  }
}

/// Filtro de la discografía del artista (ronda 3, F1).
/// Filtro de la discografía por `record_type` de Deezer.
///
/// Ronda 3 bis: sencillos y EP van **separados**. Iban juntos bajo "Sencillos
/// y EP" y el resultado desconcertaba, con razón: verificado contra la API en
/// vivo, Deezer marca como `single` lanzamientos de hasta 3 pistas (el tema
/// más sus remezclas) y como `ep` lanzamientos de 4-5. No es un fallo de
/// clasificación nuestro — es cómo publica la industria — pero meterlos en una
/// píldora que dice "Sencillos" hacía parecer que sí. Con las etiquetas
/// separadas, un EP de 5 pistas aparece bajo "EP", que es exactamente lo que
/// es.
enum _DiscographyFilter {
  todo('Todo'),
  albumes('Álbumes'),
  sencillos('Sencillos'),
  eps('EP');

  const _DiscographyFilter(this.label);
  final String label;
}
