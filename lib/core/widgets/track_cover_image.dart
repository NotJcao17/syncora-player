import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../cache/cover_cache_service.dart';
import '../utils/deezer_image.dart';
import '../cache/app_image_cache.dart';

/// Portada de una pista que prefiere el archivo descargado en disco antes que
/// la URL de Deezer.
///
/// Las descargas ya guardaban la portada localmente (`CoverCacheService
/// .downloadAndCacheCover`), pero solo la pantalla de Descargas la usaba: el
/// resto de la app pedía siempre la URL remota, así que sin conexión las
/// portadas de canciones descargadas aparecían vacías.
class TrackCoverImage extends StatefulWidget {
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
  State<TrackCoverImage> createState() => _TrackCoverImageState();
}

class _TrackCoverImageState extends State<TrackCoverImage> {
  /// Reintentos ya consumidos para la URL vigente (ronda 3, A7).
  ///
  /// Síntoma que corrige: *"algunas portadas no se ven en el celular en
  /// ciertas ejecuciones, creo que después de que haya pasado un tiempo"*.
  /// La causa más probable es la misma que ya costó tres rondas en Inicio
  /// (§6.9 de `correcciones_qa_post_fase_7.md`): en un arranque en frío
  /// Android tarda un par de segundos en tener DNS utilizable, las primeras
  /// cargas de imagen fallan, y `CachedNetworkImage` se queda mostrando su
  /// `errorWidget` para ese widget hasta que algo lo reconstruya — cosa que
  /// en una lista que no se toca no pasa nunca.
  ///
  /// Reintento **acotado y decreciente en frecuencia**, no un bucle: dos
  /// intentos extra como mucho, con esperas de 2 s y 6 s. Cambiar la key
  /// fuerza a `CachedNetworkImage` a rehacer la petición (Flutter ya saca del
  /// `ImageCache` las entradas que fallaron, así que no hay nada rancio que
  /// invalidar a mano).
  ///
  /// Precisión sobre el alcance del tope (revisión de la ronda 3): el
  /// presupuesto es **por instancia de `State`**, no por URL. En una lista con
  /// reciclado, sacar una fila de pantalla y volver a traerla destruye y
  /// recrea su `State`, así que ese tope se renueva. Se acepta a propósito:
  /// las esperas de 2 s/6 s siguen aplicando en cada ciclo, así que no puede
  /// degenerar en una ráfaga, y llevar el presupuesto a una tabla global por
  /// URL costaría una estructura que habría que podar a mano.
  int _attempt = 0;
  bool _retryScheduled = false;

  static const int _maxRetries = 2;
  static const List<Duration> _retryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 6),
  ];

  @override
  void didUpdateWidget(TrackCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Portada distinta: el presupuesto de reintentos se reinicia.
    if (oldWidget.coverUrl != widget.coverUrl || oldWidget.trackId != widget.trackId) {
      _attempt = 0;
      _retryScheduled = false;
    }
  }

  void _scheduleRetry() {
    if (_retryScheduled || _attempt >= _maxRetries) return;
    _retryScheduled = true;
    final delay = _retryDelays[_attempt.clamp(0, _retryDelays.length - 1)];
    Future<void>.delayed(delay, () {
      if (!mounted) return;
      setState(() {
        _attempt++;
        _retryScheduled = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final fallback = widget.placeholder ??
        Container(
          width: widget.width,
          height: widget.height,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        );

    final local = CoverCacheService.localCoverFileSync(widget.trackId);

    Widget localImage(File file) => Image.file(
          file,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          cacheWidth: widget.memCacheWidth,
          cacheHeight: widget.memCacheHeight,
          // `Image.file` usa por defecto un filtrado mas basto que el de
          // `CachedNetworkImage`.
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => fallback,
        );

    // Miniaturas: el archivo local basta y evita ir a la red.
    if (widget.preferredSize == null && local != null) return localImage(local);

    if (widget.coverUrl.isEmpty) return local != null ? localImage(local) : fallback;

    final url = widget.preferredSize != null
        ? DeezerImage.atSize(widget.coverUrl, widget.preferredSize!)
        : widget.coverUrl;

    return CachedNetworkImage(
      cacheManager: AppImageCache.instance,
      // Ronda 4: la animación por defecto (500 ms) se reproducía también al
      // leer de la caché en disco, y en cada arranque parecía que las
      // portadas "volvían a cargar". Con una más corta ya no se nota.
      fadeInDuration: const Duration(milliseconds: 120),
      fadeOutDuration: const Duration(milliseconds: 80),
      key: ValueKey('$url#$_attempt'),
      imageUrl: url,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      memCacheWidth: widget.memCacheWidth,
      memCacheHeight: widget.memCacheHeight,
      filterQuality: FilterQuality.medium,
      placeholder: (_, _) => local != null ? localImage(local) : fallback,
      errorWidget: (_, _, _) {
        // Se agenda fuera del build: llamar a setState desde aquí dispararía
        // un rebuild en mitad del propio build.
        _scheduleRetry();
        return local != null ? localImage(local) : fallback;
      },
    );
  }
}
