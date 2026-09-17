import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Caché persistente con TTL para respuestas del catálogo de Deezer.
///
/// Por qué en archivos y no en Drift: lo único que hace falta guardar es un
/// blob JSON por clave con su fecha, sin consultas, sin relaciones y sin
/// necesidad de migrar nada. Una tabla nueva obligaría a subir
/// `schemaVersion`, regenerar el código de Drift y escribir una migración
/// para algo que es, literalmente, un archivo con fecha.
///
/// Motivo de existir: Inicio arrancaba **en blanco** en cada arranque en frío
/// mientras esperaba a Deezer (y quedaba vacía del todo sin conexión). Con
/// esto, el arranque siguiente pinta contenido al instante y solo revalida
/// contra la red cuando el TTL venció.
///
/// ⚠️ No guarda mixes: esos son deliberadamente efímeros (ver
/// `mix_engine.dart`). Acá solo viven respuestas del catálogo público, que
/// son idénticas para todos los usuarios y no contienen nada personal.
class ApiCache {
  ApiCache({Directory? directory}) : _explicitDirectory = directory;

  final Directory? _explicitDirectory;
  Directory? _directory;
  Future<Directory?>? _directoryFuture;

  /// Capa en memoria por encima del disco: dentro de una misma sesión, varias
  /// secciones de Inicio piden la misma clave (p. ej. la lista de géneros) y
  /// no tiene sentido releer y re-decodificar el archivo cada vez.
  ///
  /// Acotada: cada playlist abierta guarda aquí sus 100 pistas ya decodificadas
  /// y una sesión larga las iría acumulando sin techo. Al pasarse de
  /// [_maxMemoryEntries] se descarta la más antigua (el disco sigue teniendo
  /// todo, así que descartar solo cuesta una lectura de archivo).
  final Map<String, _MemoryEntry> _memory = {};

  static const int _maxMemoryEntries = 24;

  void _rememberInMemory(String key, Object? payload, DateTime cachedAt) {
    _memory.remove(key);
    if (_memory.length >= _maxMemoryEntries) {
      _memory.remove(_memory.keys.first);
    }
    _memory[key] = _MemoryEntry(payload: payload, cachedAt: cachedAt);
  }

  /// En tests no hay `path_provider`, así que el caché vive solo en memoria.
  static bool get _isTestEnv => !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

  Future<Directory?> _resolveDirectory() {
    if (_directory != null) return Future.value(_directory);
    if (_isTestEnv && _explicitDirectory == null) return Future.value(null);
    return _directoryFuture ??= () async {
      try {
        final dir = _explicitDirectory ?? Directory(p.join((await getApplicationDocumentsDirectory()).path, 'api_cache'));
        if (!await dir.exists()) await dir.create(recursive: true);
        _directory = dir;
        return dir;
      } catch (_) {
        // Sin disco escribible el caché simplemente no persiste; la app sigue
        // funcionando contra la red.
        return null;
      }
    }();
  }

  static String _sanitize(String key) => key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  static String _fileNameFor(String key) => '${_sanitize(key)}.json';

  /// Devuelve el JSON guardado para [key] si existe y no superó [ttl].
  Future<Object?> read(String key, Duration ttl) async {
    final memoryHit = _memory[key];
    if (memoryHit != null) {
      if (DateTime.now().difference(memoryHit.cachedAt) <= ttl) return memoryHit.payload;
      _memory.remove(key);
      return null;
    }

    final dir = await _resolveDirectory();
    if (dir == null) return null;

    try {
      final file = File(p.join(dir.path, _fileNameFor(key)));
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final cachedAtMs = decoded['cached_at'] as int?;
      if (cachedAtMs == null) return null;
      final cachedAt = DateTime.fromMillisecondsSinceEpoch(cachedAtMs);
      if (DateTime.now().difference(cachedAt) > ttl) return null;
      final payload = decoded['payload'];
      _rememberInMemory(key, payload, cachedAt);
      return payload;
    } catch (_) {
      // Archivo corrupto o a medio escribir: se trata como "no hay caché".
      return null;
    }
  }

  Future<void> write(String key, Object payload) async {
    _rememberInMemory(key, payload, DateTime.now());

    final dir = await _resolveDirectory();
    if (dir == null) return;

    try {
      final file = File(p.join(dir.path, _fileNameFor(key)));
      // Escritura atómica: sin esto, cerrar la app a mitad de guardar dejaba
      // un JSON truncado que el `read` de arriba descartaba en cada arranque
      // posterior — caché permanentemente frío sin ninguna señal visible.
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode({
        'cached_at': DateTime.now().millisecondsSinceEpoch,
        'payload': payload,
      }));
      await temp.rename(file.path);
    } catch (_) {}
  }

  /// Patrón de uso normal: devolver lo cacheado si sigue fresco y, si no,
  /// pedirlo a la red y guardarlo.
  ///
  /// Si la red falla y hay una copia vencida en disco, se devuelve esa copia
  /// en vez de propagar el error ([staleOnError]): más vale un chart de ayer
  /// que una pantalla vacía. Solo se rinde cuando no hay absolutamente nada.
  Future<T> fetch<T>({
    required String key,
    required Duration ttl,
    required Future<T> Function() fetcher,
    required Object Function(T value) encode,
    required T Function(Object json) decode,
    bool staleOnError = true,
  }) async {
    final cached = await read(key, ttl);
    if (cached != null) {
      try {
        return decode(cached);
      } catch (_) {}
    }

    try {
      final fresh = await fetcher();
      unawaited(write(key, encode(fresh)));
      return fresh;
    } catch (e) {
      if (staleOnError) {
        final stale = await read(key, const Duration(days: 365));
        if (stale != null) {
          try {
            return decode(stale);
          } catch (_) {}
        }
      }
      rethrow;
    }
  }

  /// Borra las entradas cuya clave empieza por [prefix].
  ///
  /// Lo usa el "tirar para recargar" de Inicio: invalidar los providers no
  /// alcanza, porque volverían a leer el mismo archivo todavía fresco y el
  /// gesto no haría nada visible. Se borran solo las claves de las secciones
  /// que el gesto refresca, no el caché entero.
  Future<void> removeWithPrefix(String prefix) async {
    _memory.removeWhere((key, _) => key.startsWith(prefix));

    final dir = await _resolveDirectory();
    if (dir == null) return;
    try {
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = p.basenameWithoutExtension(entity.path);
        if (name.startsWith(_sanitize(prefix))) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Borra todo el caché de catálogo (usado por "borrar caché" de Ajustes).
  Future<void> clear() async {
    _memory.clear();
    final dir = await _resolveDirectory();
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
      _directory = null;
      _directoryFuture = null;
    } catch (_) {}
  }
}

class _MemoryEntry {
  final Object? payload;
  final DateTime cachedAt;

  const _MemoryEntry({required this.payload, required this.cachedAt});
}

final apiCacheProvider = Provider<ApiCache>((ref) => ApiCache());

/// TTLs por tipo de contenido. Agrupados acá para que la política de frescura
/// de Inicio se lea de un vistazo en vez de estar repartida por los providers.
class CacheTtl {
  /// Catálogo prácticamente inmutable (lista de géneros, tops por país).
  static const Duration catalog = Duration(days: 7);

  /// Charts y playlists editoriales: Deezer los mueve a diario como mucho.
  static const Duration charts = Duration(hours: 6);

  /// Contenido derivado del usuario que se recalcula una vez al día
  /// (novedades de sus artistas).
  static const Duration daily = Duration(hours: 24);
}
