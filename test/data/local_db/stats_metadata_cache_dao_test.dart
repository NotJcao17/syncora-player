import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/daos/stats_metadata_cache_dao.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';

/// Bundle de polish post-7.G: [StatsMetadataCacheDao] evita que
/// `enrichedArtistsProvider`/`enrichedTracksProvider` golpeen Deezer en vivo
/// por cada id en cada carga de Estadísticas (causa del lag/parpadeo de
/// ~15s reportado).
void main() {
  group('StatsMetadataCacheDao', () {
    late SyncoraDatabase db;

    setUp(() {
      db = SyncoraDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('getMany devuelve vacío si no hay nada cacheado', () async {
      final result = await db.statsMetadataCacheDao.getMany(StatsEntityType.artist, {1, 2, 3});
      expect(result, isEmpty);
    });

    test('upsert seguido de getMany devuelve la fila cacheada', () async {
      await db.statsMetadataCacheDao.upsert(
        entityType: StatsEntityType.artist,
        entityId: 42,
        primaryName: 'Test Artist',
        coverUrl: 'https://example.com/cover.jpg',
      );

      final result = await db.statsMetadataCacheDao.getMany(StatsEntityType.artist, {42});
      expect(result[42]!.primaryName, 'Test Artist');
      expect(result[42]!.coverUrl, 'https://example.com/cover.jpg');
      expect(result[42]!.secondaryName, isNull);
    });

    test('artista y canción con el mismo id no se pisan (entityType compuesto en la key)', () async {
      await db.statsMetadataCacheDao.upsert(
        entityType: StatsEntityType.artist,
        entityId: 7,
        primaryName: 'Some Artist',
        coverUrl: 'artist-cover',
      );
      await db.statsMetadataCacheDao.upsert(
        entityType: StatsEntityType.track,
        entityId: 7,
        primaryName: 'Some Track',
        secondaryName: 'Some Track Artist',
        coverUrl: 'track-cover',
      );

      final artists = await db.statsMetadataCacheDao.getMany(StatsEntityType.artist, {7});
      final tracks = await db.statsMetadataCacheDao.getMany(StatsEntityType.track, {7});

      expect(artists[7]!.primaryName, 'Some Artist');
      expect(tracks[7]!.primaryName, 'Some Track');
      expect(tracks[7]!.secondaryName, 'Some Track Artist');
    });

    test('upsert repetido sobre el mismo id actualiza en vez de duplicar', () async {
      await db.statsMetadataCacheDao.upsert(
        entityType: StatsEntityType.artist,
        entityId: 1,
        primaryName: 'Old Name',
        coverUrl: 'old-cover',
      );
      await db.statsMetadataCacheDao.upsert(
        entityType: StatsEntityType.artist,
        entityId: 1,
        primaryName: 'New Name',
        coverUrl: 'new-cover',
      );

      final result = await db.statsMetadataCacheDao.getMany(StatsEntityType.artist, {1});
      expect(result.length, 1);
      expect(result[1]!.primaryName, 'New Name');
    });

    test('getMany con ids vacíos no consulta la base y devuelve vacío', () async {
      final result = await db.statsMetadataCacheDao.getMany(StatsEntityType.artist, {});
      expect(result, isEmpty);
    });
  });
}
