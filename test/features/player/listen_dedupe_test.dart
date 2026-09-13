import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/daos/listening_history_dao.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';

/// Ronda 3, C1 (hallazgo H-R3-5).
///
/// Sintoma reportado: "en el historial de reproduccion aparecen canciones 2
/// veces", con la sospecha añadida de que media cancion escuchada antes de
/// cerrar la app y el resto despues contaba como dos reproducciones en
/// Estadisticas. Ambos casos son el mismo: `_recordListenEntry` insertaba una
/// fila nueva cada vez que se cruzaba el umbral, sin mirar si esa pista ya
/// tenia una escucha reciente.
void main() {
  late SyncoraDatabase db;
  late ListeningHistoryDao dao;

  setUp(() {
    db = SyncoraDatabase(NativeDatabase.memory());
    dao = ListeningHistoryDao(db);
  });

  tearDown(() => db.close());

  Future<int> insertAt(DateTime when, {int trackId = 42, int ms = 30000}) async {
    return db.into(db.listeningHistory).insert(
          ListeningHistoryCompanion.insert(
            trackId: trackId,
            artistId: 1,
            albumId: 1,
            durationListenedMs: ms,
            listenedAt: Value(when),
          ),
        );
  }

  group('findRecentEntryForTrack', () {
    test('encuentra una escucha dentro de la ventana', () async {
      final id = await insertAt(DateTime.now().subtract(const Duration(minutes: 2)));

      final found = await dao.findRecentEntryForTrack(
        42,
        DateTime.now().subtract(const Duration(minutes: 10)),
      );

      expect(found?.id, id);
    });

    test('ignora una escucha mas antigua que la ventana', () async {
      // Volver a poner la misma cancion horas despues es una reproduccion
      // nueva de verdad, y debe contar como tal.
      await insertAt(DateTime.now().subtract(const Duration(hours: 3)));

      final found = await dao.findRecentEntryForTrack(
        42,
        DateTime.now().subtract(const Duration(minutes: 10)),
      );

      expect(found, isNull);
    });

    test('no confunde pistas distintas', () async {
      await insertAt(DateTime.now(), trackId: 99);

      final found = await dao.findRecentEntryForTrack(
        42,
        DateTime.now().subtract(const Duration(minutes: 10)),
      );

      expect(found, isNull);
    });

    test('devuelve la mas reciente si hay varias', () async {
      await insertAt(DateTime.now().subtract(const Duration(minutes: 8)));
      final reciente = await insertAt(DateTime.now().subtract(const Duration(minutes: 1)));

      final found = await dao.findRecentEntryForTrack(
        42,
        DateTime.now().subtract(const Duration(minutes: 10)),
      );

      expect(found?.id, reciente);
    });
  });

  group('acumular sobre una escucha reutilizada', () {
    test('los minutos se suman en vez de pisarse', () async {
      // Escenario del reporte: media cancion, cierro la app, vuelvo y la
      // termino. Debe quedar UNA escucha con los minutos completos, no dos
      // escuchas de medio tema cada una.
      final id = await insertAt(DateTime.now(), ms: 90000);

      final previa = await dao.findRecentEntryForTrack(
        42,
        DateTime.now().subtract(const Duration(minutes: 10)),
      );
      await dao.updateListenedDuration(previa!.id, previa.durationListenedMs + 120000);

      final filas = await dao.getRecentHistory();
      expect(filas.length, 1, reason: 'una sola escucha, no dos');
      expect(filas.single.id, id);
      expect(filas.single.durationListenedMs, 210000);
    });

    test('reabrir para corregir deja la fila pendiente de subir de nuevo', () async {
      // `updateListenedDuration` limpia `syncedAt` para que el valor corregido
      // llegue a la nube. El upsert remoto usa (user_id, track_id,
      // listened_at), asi que actualiza la misma fila y no la duplica.
      final id = await insertAt(DateTime.now());
      await dao.markSynced(id);
      expect((await dao.getUnsyncedHistory()), isEmpty);

      await dao.updateListenedDuration(id, 200000);

      final pendientes = await dao.getUnsyncedHistory();
      expect(pendientes.map((e) => e.id).toList(), [id]);
    });
  });
}
