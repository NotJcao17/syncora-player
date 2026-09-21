import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/apis/deezer_api.dart';
import 'package:syncora_player/data/local_db/daos/listening_history_dao.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/data/models/deezer/deezer_album.dart';
import 'package:syncora_player/features/stats/genre_backfill_service.dart';

/// H-S6: las 290 escuchas de la base de desarrollo tenian las 290 el genero
/// en NULL, porque Deezer no devuelve genero en ningun endpoint de cancion.
/// Se resuelve por album (`/album/{id}` -> `genres.data[0].name`) y se cachea.
class _FakeDeezerApi extends DeezerApi {
  final Map<int, String> generosPorAlbum;
  final Set<int> fallan;
  final List<int> pedidos = [];

  _FakeDeezerApi({this.generosPorAlbum = const {}, this.fallan = const {}});

  @override
  Future<DeezerAlbum> getAlbum(int id) async {
    pedidos.add(id);
    if (fallan.contains(id)) throw Exception('fallo de red simulado');
    return DeezerAlbum(
      id: id,
      title: 'Album $id',
      artistName: 'Artista',
      artistId: 1,
      coverUrl: '',
      trackCount: 1,
      releaseDate: '',
      genreName: generosPorAlbum[id] ?? '',
    );
  }
}

void main() {
  late SyncoraDatabase db;
  late ListeningHistoryDao dao;

  setUp(() {
    db = SyncoraDatabase(NativeDatabase.memory());
    dao = ListeningHistoryDao(db);
  });

  tearDown(() => db.close());

  Future<int> escucha({required int albumId, int trackId = 1, String? genre}) =>
      db.into(db.listeningHistory).insert(
            ListeningHistoryCompanion.insert(
              trackId: trackId,
              artistId: 1,
              albumId: albumId,
              durationListenedMs: 180000,
              genre: Value(genre),
            ),
          );

  Future<List<String?>> generos() async {
    final rows = await db.select(db.listeningHistory).get();
    return rows.map((r) => r.genre).toList();
  }

  test('rellena el genero de las escuchas a partir del album', () async {
    await escucha(albumId: 10, trackId: 1);
    await escucha(albumId: 10, trackId: 2);
    await escucha(albumId: 20, trackId: 3);

    final api = _FakeDeezerApi(generosPorAlbum: {10: 'Electro', 20: 'Rock'});
    final filled = await GenreBackfillService(deezerApi: api, dao: dao).run();

    expect(filled, 3);
    expect(await generos(), containsAll(['Electro', 'Electro', 'Rock']));
    // Un album = una peticion, aunque tenga varias escuchas.
    expect(api.pedidos, hasLength(2));
  });

  test('no vuelve a pedir un album ya resuelto', () async {
    await escucha(albumId: 10, trackId: 1);
    final api = _FakeDeezerApi(generosPorAlbum: {10: 'Electro'});
    final service = GenreBackfillService(deezerApi: api, dao: dao);
    await service.run();

    // Escucha nueva del mismo album: debe resolverse con el cache, sin red.
    await escucha(albumId: 10, trackId: 99);
    final filled = await service.run();

    expect(filled, 1);
    expect(api.pedidos, hasLength(1), reason: 'el album ya estaba cacheado');
  });

  test('cachea tambien el album sin genero para no reintentarlo siempre', () async {
    await escucha(albumId: 10, trackId: 1);
    final api = _FakeDeezerApi(generosPorAlbum: const {});
    final service = GenreBackfillService(deezerApi: api, dao: dao);

    await service.run();
    await service.run();

    expect(api.pedidos, hasLength(1));
    expect(await generos(), [null]);
  });

  test('un album que falla se reintenta en la siguiente corrida', () async {
    await escucha(albumId: 10, trackId: 1);
    final api = _FakeDeezerApi(generosPorAlbum: {10: 'Rock'}, fallan: {10});
    final service = GenreBackfillService(deezerApi: api, dao: dao);

    expect(await service.run(), 0);
    expect(api.pedidos, hasLength(1));

    await service.run();
    expect(api.pedidos, hasLength(2), reason: 'no se cachea un fallo de red');
  });

  test('no toca las escuchas que ya tienen genero', () async {
    await escucha(albumId: 10, trackId: 1, genre: 'Jazz');
    final api = _FakeDeezerApi(generosPorAlbum: {10: 'Electro'});

    expect(await GenreBackfillService(deezerApi: api, dao: dao).run(), 0);
    expect(await generos(), ['Jazz']);
    expect(api.pedidos, isEmpty);
  });

  test('el relleno deja las filas pendientes de subir a la nube', () async {
    final id = await escucha(albumId: 10, trackId: 1);
    await dao.markSynced(id);

    await GenreBackfillService(
      deezerApi: _FakeDeezerApi(generosPorAlbum: {10: 'Electro'}),
      dao: dao,
    ).run();

    final pendientes = await dao.getUnsyncedHistory();
    expect(pendientes.map((e) => e.id), contains(id),
        reason: 'sin esto el genero se quedaria solo en local');
  });
}
