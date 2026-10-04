import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

class CoverCacheService {
  bool get _isTestEnv => Platform.environment.containsKey('FLUTTER_TEST');

  /// Ruta del directorio de portadas, memorizada tras la primera resolución.
  /// `getApplicationDocumentsDirectory()` es async, así que sin este caché no
  /// hay forma de que un `build()` sincrónico sepa si una portada descargada
  /// existe en disco (ver [localCoverFileSync]).
  static String? _cachedCoverDir;

  Future<String> _getCoverDir() async {
    if (kIsWeb) return '';
    final cached = _cachedCoverDir;
    if (cached != null) return cached;
    final base = (await getApplicationDocumentsDirectory()).path;
    final dir = Directory('$base/syncora/covers');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _cachedCoverDir = dir.path;
    return dir.path;
  }

  /// Prepara [localCoverFileSync] resolviendo el directorio una vez al arrancar.
  Future<void> warmUp() => _getCoverDir();

  /// Portada local de una pista descargada, o `null` si no está en disco.
  /// Sincrónico a propósito: lo consumen `build()`s de listas, donde un
  /// `FutureBuilder` por fila provocaría parpadeo en cada scroll.
  static File? localCoverFileSync(int? trackId) {
    if (kIsWeb || trackId == null) return null;
    final dir = _cachedCoverDir;
    if (dir == null) return null;
    final file = File('$dir/$trackId.jpg');
    return file.existsSync() ? file : null;
  }

  Future<File> _getIndexFile() async {
    final coverDir = await _getCoverDir();
    return File('$coverDir/index.json');
  }

  Future<Map<String, dynamic>> _loadIndex() async {
    if (_isTestEnv || kIsWeb) return {};
    try {
      final indexFile = await _getIndexFile();
      if (indexFile.existsSync()) {
        final content = indexFile.readAsStringSync();
        return jsonDecode(content) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  Future<void> _saveIndex(Map<String, dynamic> index) async {
    if (_isTestEnv || kIsWeb) return;
    try {
      final indexFile = await _getIndexFile();
      indexFile.writeAsStringSync(jsonEncode(index));
    } catch (_) {}
  }

  Future<String> downloadAndCacheCover(String coverUrl, int trackId) async {
    if (coverUrl.isEmpty || kIsWeb) return '';
    
    final coverDir = await _getCoverDir();
    final localPath = '$coverDir/$trackId.jpg';
    final file = File(localPath);

    try {
      final request = await HttpClient().getUrl(Uri.parse(coverUrl));
      final response = await request.close();
      if (response.statusCode == 200) {
        final bytes = await consolidateHttpClientResponseBytes(response);
        // Ronda 5: una respuesta cortada o que no es una imagen dejaba un
        // archivo que nunca se podía mostrar (y como existía en disco, la
        // fila ni siquiera intentaba la red).
        if (!looksLikeImage(bytes)) return '';
        file.writeAsBytesSync(bytes, flush: true);

        final index = await _loadIndex();
        index[coverUrl] = {
          'localPath': localPath,
          'trackId': trackId,
          'lastAccess': DateTime.now().millisecondsSinceEpoch,
          'sizeBytes': bytes.length,
        };
        // Ronda 5 (H-R5-4): antes aquí corría un LRU de 200 entradas que
        // BORRABA portadas de canciones descargadas a partir de la 201. Esta
        // carpeta no es una caché: cada archivo acompaña a una descarga.
        await _saveIndex(index);
        return localPath;
      }
    } catch (_) {}
    return '';
  }

  /// JPEG, PNG o WebP de un tamaño mínimo razonable.
  @visibleForTesting
  static bool looksLikeImage(List<int> bytes) {
    if (bytes.length < 256) return false;
    final isJpeg = bytes[0] == 0xFF && bytes[1] == 0xD8;
    final isPng = bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47;
    final isWebp = bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46;
    return isJpeg || isPng || isWebp;
  }

  /// Tamaño en disco de las portadas de las pistas descargadas.
  Future<int> getCacheSizeBytes() async {
    if (kIsWeb) return 0;
    final coverDir = await _getCoverDir();
    final dir = Directory(coverDir);
    if (!dir.existsSync()) return 0;

    int totalBytes = 0;
    for (final entity in dir.listSync()) {
      if (entity is File) {
        totalBytes += entity.lengthSync();
      }
    }
    return totalBytes;
  }
}

final coverCacheServiceProvider = Provider<CoverCacheService>((ref) {
  return CoverCacheService();
});
