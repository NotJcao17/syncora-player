import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'cover_cache_service.dart';

/// Espacio en disco que Configuración muestra, además del audio descargado
/// (que ya viene de la BD vía `watchAllDownloadedTracksProvider`).
///
/// Son dos cosas distintas que antes se confundían bajo "portadas":
/// - [downloadCoverBytes]: portadas de las pistas **descargadas**
///   (`syncora/covers`, [CoverCacheService]). Son parte de la descarga — sin
///   ellas la pista se ve sin portada offline — así que no se borran con la
///   caché, solo con "Borrar todas las descargas".
/// - [imageCacheBytes]: la caché real de imágenes al navegar, la de
///   `CachedNetworkImage` ([DefaultCacheManager]). Es desechable: se vuelve a
///   bajar cuando hace falta.
class StorageUsage {
  const StorageUsage({required this.downloadCoverBytes, required this.imageCacheBytes});

  final int downloadCoverBytes;
  final int imageCacheBytes;
}

Future<int> _directorySizeBytes(Directory dir) async {
  if (!await dir.exists()) return 0;
  var total = 0;
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      try {
        total += await entity.length();
      } catch (_) {}
    }
  }
  return total;
}

Future<Directory?> _imageCacheDir() async {
  if (kIsWeb) return null;
  try {
    final base = await getTemporaryDirectory();
    return Directory(p.join(base.path, DefaultCacheManager.key));
  } catch (_) {
    return null;
  }
}

final storageUsageProvider = FutureProvider.autoDispose<StorageUsage>((ref) async {
  var coverBytes = 0;
  var imageBytes = 0;
  try {
    coverBytes = await ref.read(coverCacheServiceProvider).getCacheSizeBytes();
  } catch (_) {}
  final dir = await _imageCacheDir();
  if (dir != null) {
    try {
      imageBytes = await _directorySizeBytes(dir);
    } catch (_) {}
  }
  return StorageUsage(downloadCoverBytes: coverBytes, imageCacheBytes: imageBytes);
});

/// Vacía la caché de imágenes de navegación (disco y memoria). No toca las
/// portadas de las descargas.
Future<void> clearImageCache() async {
  try {
    await DefaultCacheManager().emptyCache();
  } catch (_) {}
  // `emptyCache` solo borra lo que su índice conoce; lo que quede en la
  // carpeta es huérfano. En Windows un archivo en uso puede no borrarse:
  // se ignora, sale en la próxima limpieza.
  final dir = await _imageCacheDir();
  if (dir != null && await dir.exists()) {
    await for (final entity in dir.list(followLinks: false)) {
      try {
        await entity.delete(recursive: true);
      } catch (_) {}
    }
  }
  PaintingBinding.instance.imageCache
    ..clear()
    ..clearLiveImages();
}
