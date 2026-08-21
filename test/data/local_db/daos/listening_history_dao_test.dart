import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';

void main() {
  group('ListeningHistoryDao Tests', () {
    late SyncoraDatabase db;

    setUp(() {
      db = SyncoraDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('recordEntry crea filas sin sincronizar (syncedAt nulo) por defecto', () async {
      await db.listeningHistoryDao.recordEntry(
        trackId: 1,
        artistId: 10,
        albumId: 100,
        durationListenedMs: 40000,
      );

      final unsynced = await db.listeningHistoryDao.getUnsyncedHistory();
      expect(unsynced.length, 1);
      expect(unsynced.first.syncedAt, isNull);
    });

    test('getUnsyncedHistory no devuelve entradas ya marcadas como sincronizadas', () async {
      final id1 = await db.listeningHistoryDao.recordEntry(
        trackId: 1,
        artistId: 10,
        albumId: 100,
        durationListenedMs: 40000,
      );
      await db.listeningHistoryDao.recordEntry(
        trackId: 2,
        artistId: 20,
        albumId: 200,
        durationListenedMs: 35000,
      );

      var unsynced = await db.listeningHistoryDao.getUnsyncedHistory();
      expect(unsynced.length, 2);

      await db.listeningHistoryDao.markSynced(id1);

      unsynced = await db.listeningHistoryDao.getUnsyncedHistory();
      expect(unsynced.length, 1);
      expect(unsynced.first.trackId, 2);
    });

    test('markSynced deja una marca de tiempo no nula', () async {
      final id = await db.listeningHistoryDao.recordEntry(
        trackId: 1,
        artistId: 10,
        albumId: 100,
        durationListenedMs: 40000,
      );

      await db.listeningHistoryDao.markSynced(id);

      final all = await db.listeningHistoryDao.getRecentHistory();
      expect(all.first.syncedAt, isNotNull);
    });

    // Evidencia de 7.0.4: personalizedSectionsProvider (home_providers.dart)
    // solo cae al fallback hardcodeado (Coldplay/Bad Bunny/Dua Lipa) cuando
    // `getTopArtistIds()` devuelve una lista vacía. Con historial real
    // acumulado (vía recordEntry, activado en 7.0.2), esa condición deja de
    // cumplirse y el provider usa los artistas reales del usuario — este
    // test verifica exactamente esa condición de la que depende el gate.
    test('getTopArtistIds refleja el historial real una vez que hay escuchas registradas', () async {
      var topArtists = await db.listeningHistoryDao.getTopArtistIds(limit: 3);
      expect(topArtists, isEmpty, reason: 'sin historial, el provider debe caer al fallback');

      // Artista 10 escuchado 3 veces, artista 20 escuchado 1 vez.
      for (var i = 0; i < 3; i++) {
        await db.listeningHistoryDao.recordEntry(
          trackId: i,
          artistId: 10,
          albumId: 100,
          durationListenedMs: 40000,
        );
      }
      await db.listeningHistoryDao.recordEntry(
        trackId: 99,
        artistId: 20,
        albumId: 200,
        durationListenedMs: 40000,
      );

      topArtists = await db.listeningHistoryDao.getTopArtistIds(limit: 3);
      expect(topArtists, isNotEmpty);
      expect(topArtists.first, 10, reason: 'el artista más escuchado debe ir primero');
      expect(topArtists, contains(20));
    });
  });
}
