import 'package:drift/drift.dart';
import '../syncora_database.dart';

part 'listening_history_dao.g.dart';

@DriftAccessor(tables: [ListeningHistory])
class ListeningHistoryDao extends DatabaseAccessor<SyncoraDatabase> with _$ListeningHistoryDaoMixin {
  ListeningHistoryDao(super.db);

  Future<int> recordEntry({
    required int trackId,
    required int artistId,
    required int albumId,
    required int durationListenedMs,
    String? genre,
  }) =>
      into(listeningHistory).insert(
        ListeningHistoryCompanion.insert(
          trackId: trackId,
          artistId: artistId,
          albumId: albumId,
          durationListenedMs: durationListenedMs,
          genre: Value(genre),
        ),
      );

  Future<List<ListeningHistoryData>> getRecentHistory({int limit = 50}) => (select(listeningHistory)
        ..orderBy([(t) => OrderingTerm(expression: t.listenedAt, mode: OrderingMode.desc)])
        ..limit(limit))
      .get();
}
