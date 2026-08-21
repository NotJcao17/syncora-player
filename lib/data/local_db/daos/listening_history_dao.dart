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

  /// Entradas aún no subidas a Supabase (`syncedAt` nulo), las más antiguas
  /// primero para respetar el orden de escucha al subirlas.
  Future<List<ListeningHistoryData>> getUnsyncedHistory({int limit = 100}) => (select(listeningHistory)
        ..where((t) => t.syncedAt.isNull())
        ..orderBy([(t) => OrderingTerm(expression: t.listenedAt, mode: OrderingMode.asc)])
        ..limit(limit))
      .get();

  /// Marca una entrada como sincronizada. Debe llamarse únicamente después de
  /// que la inserción/upsert remota en Supabase haya tenido éxito (Fase
  /// 7.0.1) — si se marca antes y la subida falla, la entrada se pierde y
  /// nunca se reintenta.
  Future<void> markSynced(int id) => (update(listeningHistory)..where((t) => t.id.equals(id)))
      .write(ListeningHistoryCompanion(syncedAt: Value(DateTime.now())));

  /// Obtiene los IDs de los artistas más escuchados por el usuario según su historial
  Future<List<int>> getTopArtistIds({int limit = 5}) async {
    final history = await getRecentHistory(limit: 100);
    if (history.isEmpty) return [];

    final counts = <int, int>{};
    for (final entry in history) {
      if (entry.artistId > 0) {
        counts[entry.artistId] = (counts[entry.artistId] ?? 0) + 1;
      }
    }

    final sorted = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(limit).map((e) => e.key).toList();
  }
}

