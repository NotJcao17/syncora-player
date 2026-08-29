import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../cache/cover_cache_service.dart';

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
    if (local != null) {
      return Image.file(
        local,
        width: width,
        height: height,
        fit: fit,
        cacheWidth: memCacheWidth,
        cacheHeight: memCacheHeight,
        // `Image.file` usa por defecto un filtrado mas basto que el de
        // `CachedNetworkImage`: sin esto, la portada grande del reproductor se
        // veia visiblemente peor al pasar a servirse desde disco.
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => fallback,
      );
    }

    if (coverUrl.isEmpty) return fallback;

    return CachedNetworkImage(
      imageUrl: coverUrl,
      width: width,
      height: height,
      fit: fit,
      memCacheWidth: memCacheWidth,
      memCacheHeight: memCacheHeight,
      placeholder: (_, _) => fallback,
      errorWidget: (_, _, _) => fallback,
    );
  }
}
