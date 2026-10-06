import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/local_db/syncora_database.dart';
import '../../features/auth/services/local_mode_storage.dart';
import 'app_storage.dart';

/// Lo que la app dejaba en la carpeta Documentos de Windows antes de pasar a
/// `appDataDirectory()`. La base va con sus archivos auxiliares de SQLite.
const legacyDocumentsEntries = [
  'syncora_local.sqlite',
  'syncora_local.sqlite-wal',
  'syncora_local.sqlite-shm',
  'syncora_local.sqlite-journal',
  'repair_state.json',
  'api_cache',
  'syncora',
];

const _markerName = '.migrated-from-documents';

/// Mueve los datos de Documentos a la carpeta de la app, una sola vez, antes
/// de que nada abra la base. Solo Windows: en Android la ruta no cambió.
///
/// Best-effort: si algo falla se deja como está y la app arranca con lo que
/// haya en la carpeta nueva (lo peor es empezar sin caché ni descargas).
Future<void> migrateWindowsDataOutOfDocuments() async {
  if (kIsWeb || !Platform.isWindows) return;
  try {
    final from = await getApplicationDocumentsDirectory();
    final to = await appDataDirectory();
    final marker = File(p.join(to.path, _markerName));
    if (marker.existsSync()) return;

    final moved = await moveLegacyEntries(from: from, to: to);
    if (moved.isNotEmpty) {
      await rebaseMovedPaths(
        from: from.path,
        to: to.path,
        dataDir: to,
        openDatabase: SyncoraDatabase.new,
        localModeStorage: SecureLocalModeStorage(),
      );
    }
    marker.writeAsStringSync(DateTime.now().toIso8601String());
  } catch (e) {
    debugPrint('[Storage] No se pudieron mover los datos de Documentos: $e');
  }
}

/// Mueve cada entrada de [legacyDocumentsEntries] que exista en [from] y no
/// exista ya en [to]. Devuelve las que movió.
@visibleForTesting
Future<List<String>> moveLegacyEntries({required Directory from, required Directory to}) async {
  final moved = <String>[];
  for (final name in legacyDocumentsEntries) {
    final src = p.join(from.path, name);
    final dst = p.join(to.path, name);
    final type = FileSystemEntity.typeSync(src);
    if (type == FileSystemEntityType.notFound) continue;
    // Nunca se pisa lo que ya esté en la carpeta nueva.
    if (FileSystemEntity.typeSync(dst) != FileSystemEntityType.notFound) continue;
    try {
      await _move(src, dst, isDirectory: type == FileSystemEntityType.directory);
      moved.add(name);
    } catch (e) {
      debugPrint('[Storage] No se pudo mover $name: $e');
    }
  }
  return moved;
}

/// `rename` es instantáneo en la misma unidad. Si Documentos está en otra (o
/// redirigido por OneDrive a otro volumen), se copia y luego se borra.
Future<void> _move(String src, String dst, {required bool isDirectory}) async {
  try {
    if (isDirectory) {
      await Directory(src).rename(dst);
    } else {
      await File(src).rename(dst);
    }
    return;
  } on FileSystemException {
    // otra unidad: copiar y borrar
  }
  if (isDirectory) {
    await _copyDirectory(Directory(src), Directory(dst));
    await Directory(src).delete(recursive: true);
  } else {
    await File(src).copy(dst);
    await File(src).delete();
  }
}

Future<void> _copyDirectory(Directory src, Directory dst) async {
  await dst.create(recursive: true);
  await for (final entity in src.list(followLinks: false)) {
    final target = p.join(dst.path, p.basename(entity.path));
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(target));
    } else if (entity is File) {
      await entity.copy(target);
    }
  }
}

/// Las descargas, sus portadas y las portadas propias guardan rutas
/// ABSOLUTAS (`C:\Users\…\Documents\syncora\downloads\123.mp4`). Tras mover
/// los archivos hay que cambiar el prefijo en la base, en los JSON de
/// `syncora/` (índice de portadas, importaciones) y en la foto del modo local.
@visibleForTesting
Future<void> rebaseMovedPaths({
  required String from,
  required String to,
  required Directory dataDir,
  required SyncoraDatabase Function() openDatabase,
  LocalModeStorage? localModeStorage,
}) async {
  final db = openDatabase();
  try {
    await rebaseDatabasePaths(db, from: from, to: to);
  } finally {
    await db.close();
  }

  final syncoraDir = Directory(p.join(dataDir.path, 'syncora'));
  if (syncoraDir.existsSync()) {
    await for (final entity in syncoraDir.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final decoded = jsonDecode(await entity.readAsString());
        final (rebased, changed) = _rebaseJson(decoded, from, to);
        if (changed) await entity.writeAsString(jsonEncode(rebased));
      } catch (_) {
        // un JSON ilegible no debe frenar el resto
      }
    }
  }

  if (localModeStorage != null) {
    final avatar = await localModeStorage.getAvatarImagePath();
    final rebased = avatar == null ? null : rebasePath(avatar, from: from, to: to);
    if (rebased != null) await localModeStorage.setAvatarImagePath(rebased);
  }
}

/// Columnas que pueden guardar una ruta absoluta dentro de la carpeta vieja.
const _pathColumns = [
  ('downloaded_tracks', 'local_audio_path'),
  ('downloaded_tracks', 'local_cover_path'),
  ('playlists', 'cover_url'),
];

@visibleForTesting
Future<void> rebaseDatabasePaths(SyncoraDatabase db, {required String from, required String to}) async {
  for (final (table, column) in _pathColumns) {
    // Prefijo exacto seguido de separador; sin LIKE para no pelear con los
    // comodines `_` y `%` que pueden aparecer en una ruta.
    for (final sep in [r'\', '/']) {
      final prefix = '$from$sep';
      await db.customStatement(
        'UPDATE $table SET $column = ? || substr($column, ?) '
        'WHERE $column IS NOT NULL AND substr($column, 1, ?) = ?',
        [to, from.length + 1, prefix.length, prefix],
      );
    }
  }
}

/// [value] con el prefijo [from] cambiado por [to], o `null` si no empieza
/// por esa carpeta.
String? rebasePath(String value, {required String from, required String to}) {
  if (value.startsWith('$from\\') || value.startsWith('$from/')) {
    return to + value.substring(from.length);
  }
  return null;
}

(Object?, bool) _rebaseJson(Object? node, String from, String to) {
  if (node is String) {
    final r = rebasePath(node, from: from, to: to);
    return r == null ? (node, false) : (r, true);
  }
  if (node is List) {
    var changed = false;
    final out = [
      for (final item in node)
        () {
          final (v, c) = _rebaseJson(item, from, to);
          changed |= c;
          return v;
        }(),
    ];
    return (out, changed);
  }
  if (node is Map) {
    var changed = false;
    final out = <String, Object?>{};
    node.forEach((key, value) {
      final (v, c) = _rebaseJson(value, from, to);
      changed |= c;
      out['$key'] = v;
    });
    return (out, changed);
  }
  return (node, false);
}
