import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

class CoverCacheService {
  static const int maxEntries = 200;
  static const int maxSizeBytes = 50 * 1024 * 1024; // 50 MB

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

  Future<ImageProvider> getCover(String coverUrl, {int? trackId}) async {
    if (coverUrl.isEmpty || kIsWeb) {
      return const AssetImage('assets/icon/icon.png');
    }

    if (trackId != null) {
      final coverDir = await _getCoverDir();
      final localFile = File('$coverDir/$trackId.jpg');
      if (localFile.existsSync()) {
        return FileImage(localFile);
      }
    }

    final index = await _loadIndex();
    if (index.containsKey(coverUrl)) {
      final entry = index[coverUrl] as Map<String, dynamic>;
      final path = entry['localPath'] as String?;
      if (path != null) {
        final file = File(path);
        if (file.existsSync()) {
          entry['lastAccess'] = DateTime.now().millisecondsSinceEpoch;
          await _saveIndex(index);
          return FileImage(file);
        }
      }
    }

    return NetworkImage(coverUrl);
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
        file.writeAsBytesSync(bytes);

        final index = await _loadIndex();
        index[coverUrl] = {
          'localPath': localPath,
          'trackId': trackId,
          'lastAccess': DateTime.now().millisecondsSinceEpoch,
          'sizeBytes': bytes.length,
        };
        await _saveIndex(index);
        await _evictLruIfNeeded();
        return localPath;
      }
    } catch (_) {}
    return '';
  }

  Future<void> _evictLruIfNeeded() async {
    final index = await _loadIndex();
    if (index.length <= maxEntries) {
      int totalSize = 0;
      for (final v in index.values) {
        totalSize += (v['sizeBytes'] as num? ?? 0).toInt();
      }
      if (totalSize <= maxSizeBytes) return;
    }

    final sortedEntries = index.entries.toList()
      ..sort((a, b) {
        final aTime = (a.value['lastAccess'] as num? ?? 0).toInt();
        final bTime = (b.value['lastAccess'] as num? ?? 0).toInt();
        return aTime.compareTo(bTime);
      });

    while (index.length > maxEntries || _calculateTotalSize(index) > maxSizeBytes) {
      if (sortedEntries.isEmpty) break;
      final oldest = sortedEntries.removeAt(0);
      final path = oldest.value['localPath'] as String?;
      if (path != null) {
        final f = File(path);
        if (f.existsSync()) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
      index.remove(oldest.key);
    }
    await _saveIndex(index);
  }

  int _calculateTotalSize(Map<String, dynamic> index) {
    int total = 0;
    for (final v in index.values) {
      total += (v['sizeBytes'] as num? ?? 0).toInt();
    }
    return total;
  }

  Future<void> pruneOrphanCovers({Set<int>? activeTrackIds}) async {
    if (kIsWeb) return;
    final coverDir = await _getCoverDir();
    final dir = Directory(coverDir);
    if (!dir.existsSync()) return;

    final index = await _loadIndex();
    final indexKeysToRemove = <String>[];

    for (final entity in dir.listSync()) {
      if (entity is File && entity.path.endsWith('.jpg')) {
        final fileName = entity.path.split(Platform.pathSeparator).last;
        final trackIdStr = fileName.replaceAll('.jpg', '');
        final trackId = int.tryParse(trackIdStr);

        if (activeTrackIds != null && trackId != null && !activeTrackIds.contains(trackId)) {
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }
    }

    for (final entry in index.entries) {
      final path = entry.value['localPath'] as String?;
      if (path == null || !File(path).existsSync()) {
        indexKeysToRemove.add(entry.key);
      }
    }

    for (final key in indexKeysToRemove) {
      index.remove(key);
    }

    await _saveIndex(index);
  }

  int get currentSizeBytes {
    return 0;
  }


  Future<void> clear() => clearAll();

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

  Future<void> clearAll() async {
    if (_isTestEnv || kIsWeb) return;

    final coverDir = await _getCoverDir();
    final dir = Directory(coverDir);
    if (dir.existsSync()) {
      for (final entity in dir.listSync()) {
        try {
          entity.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }
}

final coverCacheServiceProvider = Provider<CoverCacheService>((ref) {
  return CoverCacheService();
});
