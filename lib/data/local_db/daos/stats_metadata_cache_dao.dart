import 'package:drift/drift.dart';
import '../syncora_database.dart';

part 'stats_metadata_cache_dao.g.dart';

/// Caché local de nombre/portada de artistas y canciones resueltos para
/// Estadísticas (bundle de polish post-7.G, hallazgo verificado): antes,
/// `enrichedArtistsProvider`/`enrichedTracksProvider` golpeaban
/// `DeezerApi.getArtist`/`getTrack` en vivo cada vez que se abría o
/// refrescaba la pantalla -- 10-20 llamadas individuales, causa del lag/
/// parpadeo de ~15s reportado. Una vez resuelto un id contra Deezer, su
/// nombre/portada no cambian con la frecuencia suficiente como para no
/// cachearlos localmente.
@DriftAccessor(tables: [StatsMetadataCache])
class StatsMetadataCacheDao extends DatabaseAccessor<SyncoraDatabase> with _$StatsMetadataCacheDaoMixin {
  StatsMetadataCacheDao(super.db);

  /// `entityType` es `'artist'` o `'track'` (ver [StatsEntityType]).
  Future<Map<int, StatsMetadataCacheData>> getMany(String entityType, Set<int> ids) async {
    if (ids.isEmpty) return {};
    final rows = await (select(statsMetadataCache)
          ..where((t) => t.entityType.equals(entityType) & t.entityId.isIn(ids)))
        .get();
    return {for (final row in rows) row.entityId: row};
  }

  Future<void> upsert({
    required String entityType,
    required int entityId,
    required String primaryName,
    String? secondaryName,
    required String coverUrl,
  }) {
    return into(statsMetadataCache).insertOnConflictUpdate(
      StatsMetadataCacheCompanion.insert(
        entityType: entityType,
        entityId: entityId,
        primaryName: primaryName,
        secondaryName: Value(secondaryName),
        coverUrl: coverUrl,
      ),
    );
  }
}

/// Constantes de `entityType` -- evita strings mágicos repetidos entre el DAO
/// y `stats_providers.dart`.
abstract class StatsEntityType {
  static const artist = 'artist';
  static const track = 'track';
}
