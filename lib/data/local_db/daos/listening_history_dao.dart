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
        ..orderBy([
          (t) => OrderingTerm(expression: t.listenedAt, mode: OrderingMode.desc),
          (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
        ])
        ..limit(limit))
      .get();

  Stream<List<ListeningHistoryData>> watchRecentHistory({int limit = 50}) => (select(listeningHistory)
        ..orderBy([
          (t) => OrderingTerm(expression: t.listenedAt, mode: OrderingMode.desc),
          (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
        ])
        ..limit(limit))
      .watch();

  /// Entradas aún no subidas a Supabase (`syncedAt` nulo), las más antiguas
  /// primero para respetar el orden de escucha al subirlas.
  Future<List<ListeningHistoryData>> getUnsyncedHistory({int limit = 100}) => (select(listeningHistory)
        ..where((t) => t.syncedAt.isNull())
        ..orderBy([(t) => OrderingTerm(expression: t.listenedAt, mode: OrderingMode.asc)])
        ..limit(limit))
      .get();

  /// Todas las entradas sin subir, SIN el límite de 100 de
  /// [getUnsyncedHistory] -- usado solo por la migración local -> cuenta
  /// (`migrateLocalListeningHistoryToAccount`), donde puede haber más de 100
  /// escuchas acumuladas en modo local antes de crear la cuenta.
  Future<List<ListeningHistoryData>> getAllUnsyncedHistory() => (select(listeningHistory)
        ..where((t) => t.syncedAt.isNull())
        ..orderBy([(t) => OrderingTerm(expression: t.listenedAt, mode: OrderingMode.asc)]))
      .get();

  /// Marca una entrada como sincronizada. Debe llamarse únicamente después de
  /// que la inserción/upsert remota en Supabase haya tenido éxito (Fase
  /// 7.0.1) — si se marca antes y la subida falla, la entrada se pierde y
  /// nunca se reintenta.
  Future<void> markSynced(int id) => (update(listeningHistory)..where((t) => t.id.equals(id)))
      .write(ListeningHistoryCompanion(syncedAt: Value(DateTime.now())));

  /// Ajusta los minutos escuchados de una entrada ya registrada.
  ///
  /// La escucha se inserta al cruzar el umbral (≈30s) para que sobreviva a que
  /// el usuario cierre la app, pero en ese momento solo se conocen esos 30s. Al
  /// terminar la reproducción se corrige con el tiempo real: sin esto, una
  /// canción de 4 minutos escuchada entera contaba como 30 segundos y las
  /// estadísticas de minutos salían muy por debajo de la realidad.
  ///
  /// Se vuelve a marcar como no sincronizada para que el nuevo valor suba a
  /// Supabase (el upsert remoto usa `user_id,track_id,listened_at`, así que
  /// actualiza la misma fila en vez de duplicarla).
  Future<void> updateListenedDuration(int id, int durationListenedMs) =>
      (update(listeningHistory)..where((t) => t.id.equals(id))).write(
        ListeningHistoryCompanion(
          durationListenedMs: Value(durationListenedMs),
          syncedAt: const Value(null),
        ),
      );

  /// Fase 7.G.3: entradas crudas de una ventana de días, sin límite
  /// artificial (a diferencia de [getTopArtistIds], que sí limita a 100) --
  /// Estadísticas necesita exactitud sobre la ventana completa, no una
  /// muestra.
  ///
  /// `.watch()` en vez de `.get()` (bug real de pruebas manuales: la
  /// tarjeta de "Tus minutos esta semana" de Inicio y las vistas Semanal/
  /// Mensual de Estadísticas usaban un `FutureProvider` que se calculaba una
  /// sola vez y quedaba cacheado, sin nada que lo invalidara cuando
  /// `recordEntry()` insertaba una escucha nueva) -- Drift reemite
  /// automáticamente cada vez que `listening_history` cambia, sin necesidad
  /// de invalidar el provider a mano desde el controlador del reproductor.
  Stream<List<ListeningHistoryData>> watchEntriesSince(DateTime cutoff) =>
      (select(listeningHistory)..where((t) => t.listenedAt.isBiggerOrEqualValue(cutoff))).watch();

  /// Borra TODO el historial local, sin importar si ya se sincronizó.
  /// Usado exclusivamente al descartar datos de modo local sobre una cuenta
  /// existente (`auth_screen.dart`, `_discardLocalLibraryAndDisableLocalMode`):
  /// sin esto, el historial local acumulado se sube igual en el próximo
  /// `syncListeningHistory()` y contamina las estadísticas/Wrapped de una
  /// cuenta que no es de donde salieron esas escuchas.
  Future<int> deleteAll() => delete(listeningHistory).go();

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

