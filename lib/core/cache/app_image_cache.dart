import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Caché en disco de las portadas (ronda 4).
///
/// `CachedNetworkImage` usa por defecto `DefaultCacheManager`, que guarda como
/// máximo **200 imágenes**. Una sola playlist de 600 canciones ya la desborda:
/// cada imagen nueva expulsaba otra, así que al reiniciar la app las portadas
/// volvían a descargarse (el "se cargan otra vez cada vez que abro"). Aquí el
/// tope sube a 2500 portadas y 60 días; a ~20 KB por miniatura son unos 50 MB
/// en el peor caso, y "Borrar caché de imágenes" en Configuración la vacía.
class AppImageCache {
  AppImageCache._();

  static const key = 'syncoraCoverCache';

  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 60),
      maxNrOfCacheObjects: 2500,
    ),
  );
}
