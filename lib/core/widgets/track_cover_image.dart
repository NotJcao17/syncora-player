import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../cache/cover_cache_service.dart';
import '../utils/deezer_image.dart';

/// Portada de una pista que prefiere el archivo descargado en disco antes que
/// la URL de Deezer.
///
/// Las descargas ya guardaban la portada localmente (`CoverCacheService
/// .downloadAndCacheCover`), pero solo la pantalla de Descargas la usaba: el
/// resto de la app pedía siempre la URL remota, así que sin conexión las
/// portadas de canciones descargadas aparecían vacías.
class TrackCoverImage extends StatelessWidget {
  final String coverUrl;
  final int? trackId;

  /// Nulos = llenar el espacio que le dé el padre (varias pantallas ya lo
  /// acotan con un `SizedBox`/`AspectRatio` propio).
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final int? memCacheWidth;
  final int? memCacheHeight;

  /// Para arte grande (la portada del reproductor): pide esa resolución al CDN
  /// de Deezer en vez de usar los 250x250 que guardan los modelos, y da
  /// prioridad a la red sobre la copia local — que se descargó en esos mismos
  /// 250x250 y por eso se veía pixelada al ampliarla. La copia local sigue
  /// usándose como respaldo si la red falla, así que offline no se pierde nada.
  final int? preferredSize;

  const TrackCoverImage({
    super.key,
    required this.coverUrl,
    required this.trackId,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.memCacheWidth,
    this.memCacheHeight,
    this.preferredSize,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = placeholder ??
        Container(
          width: width,
          height: height,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        );

    final local = CoverCacheService.localCoverFileSync(trackId);

    Widget localImage(File file) => Image.file(
          file,
          width: width,
          height: height,
          fit: fit,
          cacheWidth: memCacheWidth,
          cacheHeight: memCacheHeight,
          // `Image.file` usa por defecto un filtrado mas basto que el de
          // `CachedNetworkImage`.
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => fallback,
        );

    // Miniaturas: el archivo local basta y evita ir a la red.
    if (preferredSize == null && local != null) return localImage(local);

    if (coverUrl.isEmpty) return local != null ? localImage(local) : fallback;

    return CachedNetworkImage(
      imageUrl: preferredSize != null ? DeezerImage.atSize(coverUrl, preferredSize!) : coverUrl,
      width: width,
      height: height,
      fit: fit,
      memCacheWidth: memCacheWidth,
      memCacheHeight: memCacheHeight,
      filterQuality: FilterQuality.medium,
      placeholder: (_, _) => local != null ? localImage(local) : fallback,
      errorWidget: (_, _, _) => local != null ? localImage(local) : fallback,
    );
  }
}
