import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_db/database_provider.dart';
import '../../data/local_db/syncora_database.dart';
import '../../features/player/player_models.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';

/// Portada de Playlist dinámica con fallback y cuadrícula 2x2 autogenerada.
class PlaylistCoverWidget extends ConsumerWidget {
  final String? coverUrl;
  final int? playlistId;
  final List<dynamic>? tracks;
  final bool isLiked;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final BoxFit fit;
  final int? memCacheWidth;
  final int? memCacheHeight;

  const PlaylistCoverWidget({
    super.key,
    this.coverUrl,
    this.playlistId,
    this.tracks,
    this.isLiked = false,
    this.width,
    this.height,
    this.borderRadius,
    this.fit = BoxFit.cover,
    this.memCacheWidth,
    this.memCacheHeight,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final effectiveRadius = borderRadius ?? BorderRadius.circular(16);

    Widget content;

    // 1. Si es "Tus me gusta" especial -> gradiente con corazón
    if (isLiked) {
      content = Container(
        decoration: const BoxDecoration(
          gradient: AppTheme.gradientLiked,
        ),
        child: Center(
          child: Icon(
            AppIcons.bold(SolarIcons.Heart),
            color: Colors.white,
            size: (width != null && width! < 100) ? 28 : 56,
          ),
        ),
      );
    }
    // 2. Si tiene portada personalizada explicita -> mostrar imagen
    else if (coverUrl != null && coverUrl!.isNotEmpty) {
      content = CachedNetworkImage(
        imageUrl: coverUrl!,
        fit: fit,
        memCacheWidth: memCacheWidth ?? 400,
        memCacheHeight: memCacheHeight ?? 400,
        placeholder: (context, url) => Container(color: AppTheme.surfaceHover),
        errorWidget: (context, url, error) => _buildFallbackIcon(),
      );
    }
    // 3. Si se pasaron pistas directamente -> construir grid 2x2 o fallback
    else if (tracks != null) {
      content = _buildGridOrFallback(tracks!);
    }
    // 4. Si se pasó playlistId -> consultar pistas de la DB y construir grid 2x2
    else if (playlistId != null) {
      final dao = ref.watch(playlistDaoProvider);
      return StreamBuilder<List<PlaylistTrack>>(
        stream: dao.watchTracksOrdered(playlistId!),
        builder: (context, snapshot) {
          final dbTracks = snapshot.data ?? [];
          final childWidget = _buildGridOrFallback(dbTracks);
          return ClipRRect(
            borderRadius: effectiveRadius,
            child: SizedBox(
              width: width,
              height: height,
              child: childWidget,
            ),
          );
        },
      );
    }
    // 5. Fallback por defecto
    else {
      content = _buildFallbackIcon();
    }

    return ClipRRect(
      borderRadius: effectiveRadius,
      child: SizedBox(
        width: width,
        height: height,
        child: content,
      ),
    );
  }

  Widget _buildGridOrFallback(List<dynamic> trackList) {
    final distinctCovers = <String>[];
    final seenAlbumKeys = <dynamic>{};

    for (final track in trackList) {
      final String cover = _extractCoverUrl(track);
      if (cover.isEmpty) continue;

      final albumKey = _extractAlbumKey(track) ?? cover;
      if (!seenAlbumKeys.contains(albumKey)) {
        seenAlbumKeys.add(albumKey);
        distinctCovers.add(cover);
        if (distinctCovers.length == 4) break;
      }
    }

    if (distinctCovers.length >= 4) {
      return Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildGridItem(distinctCovers[0])),
                Expanded(child: _buildGridItem(distinctCovers[1])),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildGridItem(distinctCovers[2])),
                Expanded(child: _buildGridItem(distinctCovers[3])),
              ],
            ),
          ),
        ],
      );
    } else if (distinctCovers.isNotEmpty) {
      return _buildGridItem(distinctCovers.first);
    }

    return _buildFallbackIcon();
  }

  Widget _buildGridItem(String url) {
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      memCacheWidth: memCacheWidth ?? 200,
      memCacheHeight: memCacheHeight ?? 200,
      placeholder: (context, url) => Container(color: AppTheme.surfaceHover),
      errorWidget: (context, url, error) => Container(
        color: AppTheme.surfaceHover,
        child: Icon(AppIcons.broken(SolarIcons.MusicNote), color: AppTheme.muted, size: 16),
      ),
    );
  }

  Widget _buildFallbackIcon() {
    return Container(
      color: AppTheme.surfaceActive,
      child: Center(
        child: Icon(
          AppIcons.broken(SolarIcons.MusicNote),
          color: AppTheme.muted,
          size: (width != null && width! < 100) ? 28 : 56,
        ),
      ),
    );
  }

  String _extractCoverUrl(dynamic track) {
    if (track is SyncoraTrack) return track.coverUrl;
    if (track is PlaylistTrack) return track.coverUrl;
    if (track is Map) return track['coverUrl']?.toString() ?? track['cover']?.toString() ?? '';
    return '';
  }

  dynamic _extractAlbumKey(dynamic track) {
    if (track is SyncoraTrack) return (track.albumId != null && track.albumId != 0) ? track.albumId : track.coverUrl;
    if (track is PlaylistTrack) return (track.albumId != 0) ? track.albumId : track.coverUrl;
    if (track is Map) return track['albumId'] ?? track['coverUrl'] ?? track['cover'];
    return null;
  }
}
