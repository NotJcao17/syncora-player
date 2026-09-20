import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';

/// El historial dejó de subir en una sola dirección: ahora también se baja de
/// la nube, porque si no cada dispositivo derivaba On Repeat, los mixes y
/// "Novedades de tus artistas" de lo que se había escuchado *solo ahí*.
void main() {
  late SyncoraDatabase db;

  setUp(() {
    db = SyncoraDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  });

  tearDown(() async => db.close());

  ListeningHistoryCompanion remote(int trackId, DateTime at) =>
      ListeningHistoryCompanion.insert(
        trackId: trackId,
        artistId: 7,
        albumId: 70,
        durationListenedMs: 180000,
        listenedAt: Value(at),
        syncedAt: Value(DateTime.now()),
      );

  test('inserta las escuchas que vienen de la nube', () async {
    final inserted = await db.listeningHistoryDao.insertRemoteEntries([
      remote(1, DateTime(2026, 9, 18, 10)),
      remote(2, DateTime(2026, 9, 18, 11)),
    ]);

    expect(inserted, 2);
    expect((await db.listeningHistoryDao.getRecentHistory()).length, 2);
  });

  test('bajar dos veces lo mismo no duplica: la clave es (pista, momento)', () async {
    final at = DateTime(2026, 9, 18, 10);
    await db.listeningHistoryDao.insertRemoteEntries([remote(1, at)]);
    final second = await db.listeningHistoryDao.insertRemoteEntries([remote(1, at)]);

    expect(second, 0);
    expect((await db.listeningHistoryDao.getRecentHistory()).length, 1);
  });

  test('la misma pista en otro momento sí es una escucha distinta', () async {
    await db.listeningHistoryDao.insertRemoteEntries([
      remote(1, DateTime(2026, 9, 18, 10)),
      remote(1, DateTime(2026, 9, 18, 12)),
    ]);

    expect((await db.listeningHistoryDao.getRecentHistory()).length, 2);
  });

  test('lo bajado llega marcado como sincronizado y no se vuelve a subir', () async {
    await db.listeningHistoryDao.insertRemoteEntries([remote(1, DateTime(2026, 9, 18, 10))]);

    // Sin `syncedAt`, el siguiente push reenviaría a la nube lo que acaba de
    // bajar de ella.
    expect(await db.listeningHistoryDao.getUnsyncedHistory(), isEmpty);
  });

  test('no pisa una escucha local pendiente de subir', () async {
    final at = DateTime(2026, 9, 18, 10);
    await db.into(db.listeningHistory).insert(
          ListeningHistoryCompanion.insert(
            trackId: 1,
            artistId: 7,
            albumId: 70,
            durationListenedMs: 1000,
            listenedAt: Value(at),
          ),
        );

    await db.listeningHistoryDao.insertRemoteEntries([remote(1, at)]);

    final all = await db.listeningHistoryDao.getRecentHistory();
    expect(all.length, 1);
    // Sigue pendiente: la fila local es la que manda, no la copia remota.
    expect((await db.listeningHistoryDao.getUnsyncedHistory()).length, 1);
  });

  test('una lista vacía no hace nada', () async {
    expect(await db.listeningHistoryDao.insertRemoteEntries([]), 0);
  });
}
