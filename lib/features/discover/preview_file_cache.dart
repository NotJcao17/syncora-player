import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Previews de Descubrir descargadas a archivos temporales (Fase 8.F, solo
/// Windows).
///
/// Medido en el PC de desarrollo: bajar una preview entera (~480 KB) con
/// HTTP tarda 0.1–0.4 s, pero abrirla en streaming con libmpv tardaba 3–4 s
/// y a veces más de 10 (conexión HTTPS nueva y sondeo del MP3 en cada
/// apertura). Con el archivo local libmpv arranca al instante, y además se
/// pre-descargan las siguientes tarjetas. En Android ExoPlayer hace streaming
/// rápido y no se usa.
class PreviewFileCache {
  PreviewFileCache({Dio? dio, Future<Directory> Function()? baseDir})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              responseType: ResponseType.bytes,
            )),
        _baseDir = baseDir ?? getTemporaryDirectory;

  final Dio _dio;
  final Future<Directory> Function() _baseDir;
  final Map<int, Future<String?>> _inFlight = {};
  final Map<int, String> _ready = {};
  Directory? _dir;

  /// Una preview de 30 s pesa ~0.5 MB; esto solo frena algo absurdo.
  static const int _maxBytes = 5 * 1024 * 1024;

  Future<Directory> _directory() async {
    final existing = _dir;
    if (existing != null) return existing;
    final dir = Directory(p.join((await _baseDir()).path, 'syncora_previews'));
    await dir.create(recursive: true);
    return _dir = dir;
  }

  /// Ruta local de la preview de [trackId], descargándola si hace falta.
  /// `null` si no se pudo (URL caducada, sin red): el llamador decide.
  Future<String?> fetch(int trackId, String url) {
    final ready = _ready[trackId];
    if (ready != null) return Future.value(ready);
    // Cuerpo de bloque, NO flecha: `Map.remove` devuelve el propio future y
    // `whenComplete` lo esperaría a sí mismo para siempre (misma trampa que
    // `SyncService._runExclusive`, ver CLAUDE.md).
    return _inFlight[trackId] ??= _download(trackId, url).whenComplete(() {
      _inFlight.remove(trackId);
    });
  }

  Future<String?> _download(int trackId, String url) async {
    try {
      final res = await _dio.get<List<int>>(url);
      final bytes = res.data;
      if (res.statusCode != 200 || bytes == null || bytes.isEmpty || bytes.length > _maxBytes) return null;
      final dir = await _directory();
      final target = File(p.join(dir.path, 'preview_$trackId.mp3'));
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(target.path);
      return _ready[trackId] = target.path;
    } catch (_) {
      return null;
    }
  }

  /// Borra las previews fuera de [keep] (las tarjetas cercanas a la actual).
  Future<void> prune(Set<int> keep) async {
    final drop = _ready.keys.where((id) => !keep.contains(id)).toList();
    for (final id in drop) {
      final path = _ready.remove(id);
      if (path == null) continue;
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  /// Al salir de Descubrir no queda nada en disco.
  Future<void> clear() async {
    _ready.clear();
    try {
      final dir = _dir ?? Directory(p.join((await _baseDir()).path, 'syncora_previews'));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}
