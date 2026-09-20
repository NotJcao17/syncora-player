import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'daos/playlist_dao.dart';
import 'database_provider.dart';

/// Limpieza **de una sola vez** de los duplicados que dejaron las versiones
/// anteriores de la app.
///
/// La causa está cerrada: `SyncService` ya serializa sus corridas, así que no
/// se vuelven a generar duplicados y no hace falta una red de seguridad
/// permanente. Pero arreglar la causa no limpia las bases que ya quedaron
/// sucias, y obligar al usuario a borrar los datos de la app no es una
/// respuesta aceptable — así que esto corre una vez, deja constancia, y no
/// vuelve a ejecutarse nunca.
///
/// La constancia es un archivo marcador en el directorio de la app. No usa la
/// base de datos a propósito: añadir una tabla de banderas obligaría a otra
/// migración de esquema por un booleano.
class DuplicateRepair {
  DuplicateRepair({required this.playlistDao, Directory? directory})
      : _explicitDirectory = directory;

  final PlaylistDao playlistDao;
  final Directory? _explicitDirectory;

  /// Versión de la reparación. Subirla vuelve a habilitar una pasada, si en el
  /// futuro hiciera falta limpiar otra cosa.
  static const String version = 'v1';

  static bool get _isTestEnv => !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

  Future<File?> _markerFile() async {
    try {
      final dir = _explicitDirectory ?? await getApplicationDocumentsDirectory();
      return File(p.join(dir.path, 'repair_state.json'));
    } catch (_) {
      return null;
    }
  }

  /// Corre la reparación si no se hizo ya. Devuelve cuántas filas eliminó, o
  /// `null` si no hacía falta correrla.
  Future<int?> runOnce() async {
    // En tests no hay `path_provider`: sin marcador no se puede garantizar el
    // "una sola vez", así que directamente no corre.
    if (_isTestEnv && _explicitDirectory == null) return null;

    final marker = await _markerFile();
    if (marker == null) return null;

    try {
      if (await marker.exists()) {
        final decoded = jsonDecode(await marker.readAsString());
        if (decoded is Map && decoded['duplicates'] == version) return null;
      }
    } catch (_) {
      // Marcador ilegible: se vuelve a reparar, que es inofensivo (la
      // reparación no hace nada sobre una base sana) y se reescribe abajo.
    }

    int removed = 0;
    try {
      removed = await playlistDao.repairDuplicates();
    } catch (_) {
      // Si la reparación falla no se marca como hecha: se reintenta en el
      // siguiente arranque.
      return null;
    }

    try {
      await marker.writeAsString(jsonEncode({'duplicates': version}));
    } catch (_) {}

    return removed;
  }
}

final duplicateRepairProvider = Provider<DuplicateRepair>((ref) {
  return DuplicateRepair(playlistDao: ref.watch(playlistDaoProvider));
});
