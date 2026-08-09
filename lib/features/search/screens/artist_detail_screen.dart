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
        api.getArtistTopTracks(id),
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
                      controller.setQueue(syncoraTracks, startIndex: i);
                      controller.play();
                    },
                    onAddToQueue: () => controller.addToQueue(track),
                  );
                },
                childCount: syncoraTracks.length,
              ),
            ),
          ),

          // Discografía
          if (_albums.isNotEmpty)
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
                          itemCount: _albums.length,
                          separatorBuilder: (ctx, index) => const SizedBox(width: 16),
                          itemBuilder: (ctx, i) {
                            final album = _albums[i];
                            final subtitleText = album.trackCount > 0
                                ? '${album.trackCount} canciones'
                                : (album.releaseDate.length >= 4
                                    ? album.releaseDate.substring(0, 4)
                                    : 'Álbum');
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
          child: IconButton(
            icon: Icon(AppIcons.outline(SolarIcons.Play), color: AppTheme.background, size: 26),
            onPressed: widget.onPressed,
          ),
        ),
      ),
    );
  }
}
