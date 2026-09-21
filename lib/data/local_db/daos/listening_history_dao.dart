import 'package:drift/drift.dart';
import '../syncora_database.dart';

part 'listening_history_dao.g.dart';

@DriftAccessor(tables: [ListeningHistory, AlbumGenreCache])
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

  /// Inserta escuchas que vienen de la nube, saltando las que ya están.
  ///
  /// La clave natural es `(trackId, listenedAt)` — la misma con la que
  /// Supabase deduplica (`20250001000007_listening_history_dedup.sql`), así
  /// que bajar dos veces el mismo historial no crea filas nuevas.
  ///
  /// Llegan con `syncedAt` puesto: ya están en la nube, y sin eso el siguiente
  /// `_syncListeningHistoryInternal` las volvería a subir.
  ///
  /// Devuelve cuántas filas se insertaron.
  Future<int> insertRemoteEntries(List<ListeningHistoryCompanion> entries) async {
    if (entries.isEmpty) return 0;

    return transaction(() async {
      var inserted = 0;
      for (final entry in entries) {
        final trackId = entry.trackId.value;
        final listenedAt = entry.listenedAt.value;

        final existing = await (select(listeningHistory)
              ..where((t) => t.trackId.equals(trackId) & t.listenedAt.equals(listenedAt))
              ..limit(1))
            .get();
        if (existing.isNotEmpty) continue;

        await into(listeningHistory).insert(entry);
        inserted++;
      }
      return inserted;
    });
  }

  /// Última escucha **propia de este dispositivo** registrada de [trackId] a
  /// partir de [since], o `null` si no hay ninguna en esa ventana (ronda 3,
  /// C1 / hallazgo H-R3-5).
  ///
  /// Sirve para no insertar una escucha nueva cuando en realidad es la
  /// continuación de una que ya se contabilizó: retroceder a una canción que
  /// ya cruzó el umbral, o partirla entre dos sesiones de la app (escuchar
  /// medio tema, cerrar, volver y terminarlo). Los dos casos salían como dos
  /// filas distintas, y por eso aparecían canciones dos veces en el historial
  /// y las reproducciones se contaban de más en Estadísticas.
  /// Excluye a propósito las filas bajadas de la nube (`fromRemote`, H-S3):
  /// fusionar la escucha de este aparato con la que quedó registrada en otro
  /// inflaba una fila, hacía desaparecer la otra escucha, y daba un resultado
  /// distinto según el orden en que hubieran corrido los syncs.
  Future<ListeningHistoryData?> findRecentEntryForTrack(
    int trackId,
    DateTime since,
  ) =>
      (select(listeningHistory)
            ..where((t) =>
                t.trackId.equals(trackId) &
                t.listenedAt.isBiggerOrEqualValue(since) &
                t.fromRemote.equals(false))
            ..orderBy([
              (t) => OrderingTerm(expression: t.listenedAt, mode: OrderingMode.desc),
              (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
            ])
            ..limit(1))
          .getSingleOrNull();

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
  Future<List<ListeningHistoryData>> getUnsyncedHistory({int limit = 1000}) => (select(listeningHistory)
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

  /// Marca un lote entero como sincronizado en una sola sentencia (H-S4).
  ///
  /// Va de la mano con la subida por lotes: si el push manda 200 escuchas en
  /// un solo upsert, marcarlas de una en una desharía la ganancia.
  Future<void> markManySynced(List<int> ids) async {
    if (ids.isEmpty) return;
    await (update(listeningHistory)..where((t) => t.id.isIn(ids)))
        .write(ListeningHistoryCompanion(syncedAt: Value(DateTime.now())));
  }

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

  // --------------------------------------------------------------------
  // Género por álbum (H-S6)
  // --------------------------------------------------------------------

  /// Álbumes que aparecen en escuchas sin género, los más recientes primero.
  ///
  /// Es la lista de trabajo del relleno de géneros. **Incluye a propósito los
  /// álbumes que ya están en [AlbumGenreCache]**: una escucha nueva de un
  /// álbum conocido también necesita que le copien el género, y eso no cuesta
  /// ninguna petición. Filtrarlos aquí (como hacía la primera versión, con un
  /// `LEFT JOIN ... IS NULL`) dejaba esas escuchas sin género para siempre —
  /// lo cazó el test "no vuelve a pedir un album ya resuelto".
  Future<List<int>> albumIdsMissingGenre({int limit = 25}) async {
    final rows = await customSelect(
      'SELECT h.album_id AS album_id '
      'FROM listening_history h '
      'WHERE h.genre IS NULL AND h.album_id > 0 '
      'GROUP BY h.album_id '
      'ORDER BY MAX(h.listened_at) DESC '
      'LIMIT ?',
      variables: [Variable.withInt(limit)],
      readsFrom: {listeningHistory},
    ).get();
    return rows.map((r) => r.read<int>('album_id')).toList();
  }

  /// Géneros ya resueltos para [albumIds].
  Future<Map<int, String>> cachedGenres(Set<int> albumIds) async {
    if (albumIds.isEmpty) return {};
    final rows =
        await (select(albumGenreCache)..where((t) => t.albumId.isIn(albumIds))).get();
    return {for (final r in rows) r.albumId: r.genre};
  }

  /// Guarda el género de un álbum. Cadena vacía = "Deezer no tiene género
  /// para este álbum", y se cachea igual para no reintentarlo en cada corrida.
  Future<void> cacheAlbumGenre(int albumId, String genre) =>
      into(albumGenreCache).insertOnConflictUpdate(
        AlbumGenreCacheData(albumId: albumId, genre: genre, fetchedAt: DateTime.now()),
      );

  /// Rellena el género de las escuchas de [albumId] que aún no lo tienen.
  ///
  /// Las deja sin sincronizar a propósito para que el género suba también a
  /// Supabase: es ahí donde lo lee la pantalla de Estadísticas cuando hay
  /// cuenta, así que rellenarlo solo en local no serviría de nada.
  Future<int> applyGenreToAlbum(int albumId, String genre) async {
    if (genre.isEmpty) return 0;
    return (update(listeningHistory)
          ..where((t) => t.albumId.equals(albumId) & t.genre.isNull()))
        .write(
      ListeningHistoryCompanion(genre: Value(genre), syncedAt: const Value(null)),
    );
  }

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

