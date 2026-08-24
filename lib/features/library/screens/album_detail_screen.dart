import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_toast.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/track_tile.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../../data/models/deezer/deezer_album.dart';
import '../../../data/models/deezer/deezer_track.dart';
import '../../../data/sync/sync_service.dart';
import '../../auth/local_mode_provider.dart';
import '../../download/widgets/download_header_button.dart';
import '../../player/audio_engine/audio_engine_state.dart';

import '../../player/player_providers.dart';

/// Pantalla de Detalle de Álbum (`/album/:id`) conectada a Deezer real.
class AlbumDetailScreen extends ConsumerStatefulWidget {
  final String albumId;

  const AlbumDetailScreen({
    super.key,
    required this.albumId,
  });

  @override
  ConsumerState<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends ConsumerState<AlbumDetailScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  DeezerAlbum? _album;
  bool _isSaved = false;
  Color? _dominantColor;

  @override
  void initState() {
    super.initState();
    _loadAlbumData();
  }

  Future<void> _loadAlbumData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final id = int.tryParse(widget.albumId) ?? 0;
    if (id == 0) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'ID de álbum inválido';
      });
      return;
    }

    try {
      final api = ref.read(deezerApiProvider);
      final album = await api.getAlbum(id);
      final savedDao = ref.read(savedAlbumDaoProvider);
      final isSaved = await savedDao.isAlbumSaved(id);

      if (mounted) {
        setState(() {
          _album = album;
          _isSaved = isSaved;
          _isLoading = false;
        });
        _extractPalette(album.coverUrl);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Error al cargar los detalles del álbum.';
        });
      }
    }
  }

  void _extractPalette(String coverUrl) async {
    if (coverUrl.isEmpty) return;
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        NetworkImage(coverUrl),
        maximumColorCount: 8,
      );
      final color = palette.darkVibrantColor?.color ?? palette.dominantColor?.color;
      if (mounted && color != null) {
        setState(() {
          _dominantColor = color;
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleSaveAlbum() async {
    if (_album == null) return;
    final savedDao = ref.read(savedAlbumDaoProvider);
    final supabaseAlbumRepo = ref.read(supabaseAlbumRepositoryProvider);

    final nowSaved = await savedDao.toggleSaveAlbum(
      albumId: _album!.id,
      title: _album!.title,
      artistName: _album!.artistName,
      coverUrl: _album!.coverUrl,
    );

    try {
      if (nowSaved) {
        await supabaseAlbumRepo.saveAlbum({
          'album_id': _album!.id,
          'title': _album!.title,
          'artist_name': _album!.artistName,
          'cover_url': _album!.coverUrl,
        });
      } else {
        await supabaseAlbumRepo.removeAlbum(_album!.id);
      }
    } catch (_) {}

    if (mounted) {
      setState(() => _isSaved = nowSaved);
      AppToast.show(
        context,
        message: nowSaved ? 'Álbum guardado en tu biblioteca' : 'Álbum eliminado de tu biblioteca',
      );
    }
  }

  String _formatTotalDuration(List<DeezerTrack> tracks) {
    final totalSec = tracks.fold<int>(0, (sum, t) => sum + t.durationSec);
    final minutes = totalSec ~/ 60;
    final seconds = totalSec % 60;
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final remMin = minutes % 60;
      return '$hours h $remMin min';
    }
    return '$minutes min $seconds s';
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(syncoraPlayerControllerProvider.notifier);
    final currentTrack = ref.watch(currentTrackProvider);
    final isPlaying = ref.watch(isPlayingProvider);
    final isDesktop = MediaQuery.of(context).size.width >= 768;
    // Fase 7.I.8: control de sincronización manual, oculto en modo local
    // (guardar/quitar álbumes ya funciona 100% local sin este botón).
    final isLocalMode = ref.watch(localModeProvider);

    if (_isLoading) {
      return const Scaffold(
        backgroundColor: AppTheme.background,
        body: Center(child: CircularProgressIndicator(color: AppTheme.primary)),
      );
    }

    if (_errorMessage != null || _album == null) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        body: ErrorStateWidget(
          message: _errorMessage ?? 'No se encontró el álbum',
          onRetry: _loadAlbumData,
        ),
      );
    }

    final album = _album!;
    final syncoraTracks = album.tracks.map((t) => t.toSyncoraTrack()).toList();
    final totalDurationStr = _formatTotalDuration(album.tracks);

    final playerState = ref.watch(playerStateProvider);
    final albumContextId = 'album_${album.id}';
    final isCurrentContext = playerState.activeContextId == albumContextId;
    final isBufferingOrPlaying = isPlaying ||
        (playerState.engine.processingState == AudioProcessingState.loading ||
         playerState.engine.processingState == AudioProcessingState.buffering);
    final showPauseHeader = isCurrentContext && isBufferingOrPlaying;

    final dominantGradientColor = _dominantColor?.withValues(alpha: 0.35) ?? AppTheme.surfaceHover.withValues(alpha: 0.3);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              dominantGradientColor,
              AppTheme.background,
              AppTheme.background,
            ],
            stops: const [0.0, 0.45, 1.0],
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: RefreshIndicator(
                onRefresh: () async {
                  if (!isLocalMode) {
                    await ref.read(syncServiceProvider).syncSavedAlbums(force: true);
                  }
                  await _loadAlbumData();
                },
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.only(
                        top: MediaQuery.of(context).padding.top + 56,
                        left: isDesktop ? 32 : 12,
                        right: isDesktop ? 32 : 12,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 8),

                            if (isDesktop)
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Container(
                                    width: 220,
                                    height: 220,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(16),
                                      boxShadow: AppTheme.glowShadow,
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(16),
                                      child: CachedNetworkImage(
                                        imageUrl: album.coverUrl,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 28),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'ÁLBUM',
                                          style: TextStyle(
                                            color: AppTheme.secondary,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: 1.5,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          album.title,
                                          style: const TextStyle(
                                            color: AppTheme.primary,
                                            fontSize: 44,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: -1,
                                          ),
                                        ),
                                        const SizedBox(height: 14),
                                        Row(
                                          children: [
                                            Text(
                                              album.artistName,
                                              style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 13),
                                            ),
                                            Text(
                                              '  •  ${album.releaseDate}  •  ${album.tracks.length} canciones, $totalDurationStr',
                                              style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              )
                            else
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Center(
                                    child: Container(
                                      width: 180,
                                      height: 180,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(20),
                                        boxShadow: AppTheme.glowHighShadow,
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(20),
                                        child: CachedNetworkImage(
                                          imageUrl: album.coverUrl,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    album.title,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: AppTheme.primary,
                                      fontSize: 28,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: -0.5,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        album.artistName,
                                        style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 13),
                                      ),
                                      Text(
                                        ' • ${album.tracks.length} canciones, $totalDurationStr',
                                        style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                                      ),
                                    ],
                                  ),
                                ],
                              ),

                            const SizedBox(height: 16),

                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                mainAxisAlignment: isDesktop ? MainAxisAlignment.start : MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  if (syncoraTracks.isNotEmpty) ...[
                                    _HeaderPlayButton(
                                      isPlaying: showPauseHeader,
                                      isLoading: isCurrentContext &&
                                          (playerState.engine.processingState == AudioProcessingState.loading ||
                                           playerState.engine.processingState == AudioProcessingState.buffering),
                                      onPressed: () {
                                        if (showPauseHeader) {
                                          controller.pause();
                                        } else if (isCurrentContext) {
                                          controller.play();
                                        } else {
                                          controller.setQueue(syncoraTracks, startIndex: 0, activeContextId: albumContextId);
                                          controller.play();
                                        }
                                      },
                                    ),
                                    const SizedBox(width: 12),
                                    DownloadHeaderButton(
                                      title: album.title,
                                      tracks: syncoraTracks,
                                    ),
                                    const SizedBox(width: 12),
                                    Consumer(
                                      builder: (context, ref, _) {
                                        final playerState = ref.watch(playerStateProvider);
                                        final isShuffle = playerState.isShuffle;

                                        return IconButton(
                                          icon: Padding(
                                            padding: const EdgeInsets.only(top: 2.0),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                Icon(
                                                  isShuffle ? AppIcons.outline(SolarIcons.Shuffle) : AppIcons.broken(SolarIcons.Shuffle),
                                                  color: isShuffle ? Colors.white : AppTheme.secondary,
                                                  size: 22,
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
                                          onPressed: () {
                                            if (isCurrentContext) {
                                              controller.toggleShuffle();
                                            } else {
                                              controller.setQueue(syncoraTracks, startIndex: 0, activeContextId: albumContextId);
                                              if (!isShuffle) {
                                                controller.toggleShuffle();
                                              }
                                              controller.play();
                                            }
                                          },
                                          tooltip: 'Aleatorio',
                                        );
                                      },
                                    ),
                                    const SizedBox(width: 16),
                                  ],
                                  if (isDesktop && !isLocalMode) ...[
                                    IconButton(
                                      icon: const Icon(Icons.refresh),
                                      color: AppTheme.secondary,
                                      onPressed: () async {
                                        await ref.read(syncServiceProvider).syncSavedAlbums(force: true);
                                        await _loadAlbumData();
                                      },
                                      tooltip: 'Sincronizar álbumes guardados',
                                    ),
                                    const SizedBox(width: 16),
                                  ],
                                  IconButton(
                                    icon: Icon(
                                      _isSaved ? AppIcons.bold(SolarIcons.Heart) : AppIcons.broken(SolarIcons.Heart),
                                      color: _isSaved ? AppTheme.primary : AppTheme.secondary,
                                      size: 24,
                                    ),
                                    onPressed: _toggleSaveAlbum,
                                    tooltip: _isSaved ? 'Eliminar de guardados' : 'Guardar álbum',
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 20),
                          ],
                        ),
                      ),
                    ),

                    if (isDesktop && syncoraTracks.isNotEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: Row(
                                  children: [
                                    const SizedBox(width: 28, child: Text('#', style: TextStyle(color: AppTheme.secondary, fontSize: 12, fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
                                    const SizedBox(width: 8),
                                    const Expanded(flex: 3, child: Padding(padding: EdgeInsets.only(left: 60), child: Text('TÍTULO', style: TextStyle(color: AppTheme.secondary, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.2)))),
                                    const SizedBox(width: 16),
                                    const Expanded(flex: 2, child: Text('ÁLBUM', style: TextStyle(color: AppTheme.secondary, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.2))),
                                    const SizedBox(width: 12),
                                    SizedBox(width: 50, child: Align(alignment: Alignment.centerRight, child: Icon(AppIcons.broken(SolarIcons.ClockCircle), color: AppTheme.secondary, size: 16))),
                                    const SizedBox(width: 52),
                                  ],
                                ),
                              ),
                              const Divider(height: 12, color: AppTheme.surfaceHover),
                            ],
                          ),
                        ),
                      ),

                    SliverPadding(
                      padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 12),
                      sliver: SliverList.builder(
                        itemCount: syncoraTracks.length,
                        itemBuilder: (ctx, i) {
                          final track = syncoraTracks[i];
                          final isPlayingTrack = currentTrack?.id == track.id;

                          return TrackTile(
                            track: track,
                            index: i,
                            isPlaying: isPlayingTrack,
                            showAlbum: true,
                            onTap: () {
                              controller.setQueue(syncoraTracks, startIndex: i, activeContextId: albumContextId);
                            },
                            onAddToQueue: () => controller.addToQueue(track),
                          );
                        },
                      ),
                    ),

                    const SliverToBoxAdapter(
                      child: SizedBox(height: 40),
                    ),
                  ],
                ),
            ),
          ),

            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 16,
              right: 16,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
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
                    ),
                  ),
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.35),
                    ),
                    child: IconButton(
                      icon: Icon(AppIcons.broken(SolarIcons.Magnifer), color: AppTheme.primary, size: 18),
                      onPressed: () => context.push('/search'),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderPlayButton extends StatefulWidget {
  final bool isPlaying;
  final bool isLoading;
  final VoidCallback onPressed;

  const _HeaderPlayButton({
    required this.isPlaying,
    this.isLoading = false,
    required this.onPressed,
  });

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
              icon: widget.isLoading
                  ? LoadingAnimationWidget.threeArchedCircle(
                      color: AppTheme.background,
                      size: 26,
                    )
                  : Icon(
                      widget.isPlaying ? AppIcons.broken(SolarIcons.Pause) : AppIcons.outline(SolarIcons.Play),
                      color: AppTheme.background,
                      size: 26,
                    ),
              onPressed: widget.onPressed,
            ),
          ),
        ),
      ),
    );
  }
}

