import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../data/apis/deezer_provider.dart';
import '../../data/local_db/daos/stats_metadata_cache_dao.dart';
import '../../data/local_db/database_provider.dart';
import '../../data/models/deezer/deezer_artist.dart';
import '../../data/models/deezer/deezer_track.dart';
import '../../data/supabase/supabase_stats_repository.dart';
import '../auth/local_mode_provider.dart';
import 'stats_calculator.dart';
import 'stats_models.dart';

final supabaseStatsRepositoryProvider = Provider<SupabaseStatsRepository>((ref) {
  return SupabaseStatsRepository();
});

/// Periodo seleccionado en el selector de la pantalla. Todo el dashboard
/// cuelga de aquí: cambiarlo recalcula tarjetas, gráfico, tops y hábitos.
final selectedStatsPeriodProvider = StateProvider<StatsPeriod>((ref) => StatsPeriod.week);

/// Snapshot del periodo pedido.
///
/// **Con cuenta, la fuente es siempre la nube** (D-24): Drift local solo ve
/// lo escuchado en ESTE aparato, y ese era uno de los motivos por los que el
/// PC y el móvil no coincidían. Solo en modo local (7.I.6) Drift es la única
/// fuente posible.
///
/// `StreamProvider` y no `FutureProvider` porque el camino local tiene que
/// reaccionar a las escuchas nuevas sin que nadie invalide nada (`watch` de
/// Drift reemite al cambiar la tabla). El camino con cuenta emite un solo
/// evento sobre el mismo tipo, para no bifurcar lo que consume la UI.
/// `autoDispose` para que salir de Estadísticas no deje vivos los streams de
/// los periodos que ya no se miran (en modo local cada uno mantiene abierta
/// una suscripción a Drift).
final statsSnapshotProvider =
    StreamProvider.autoDispose.family<StatsSnapshot, StatsPeriod>((ref, period) async* {
  final isLocalMode = ref.watch(localModeProvider);
  final now = DateTime.now();

  if (isLocalMode) {
    yield* _localSnapshots(ref, period, now);
    return;
  }

  final repo = ref.watch(supabaseStatsRepositoryProvider);

  if (period.usesMonthlyAggregate) {
    yield await _monthlySnapshot(repo, period, now);
    return;
  }

  final start = period.startFrom(now)!;
  final end = now.add(const Duration(days: 1));
  final snapshot = await repo.fetchStats(from: start, to: end, bucket: period.bucket);
  if (snapshot == null) {
    yield const StatsSnapshot();
    return;
  }

  // Periodo anterior del mismo tamaño, solo para el "+18 % vs antes". Es una
  // segunda petición de ~1 KB: se pide el total, no los tops.
  final days = period.days!;
  final prevStart = start.subtract(Duration(days: days));
  final prev = await repo.fetchStats(
    from: prevStart,
    to: start,
    bucket: period.bucket,
    topN: 1,
  );

  yield snapshot.copyWith(previousTotalMs: prev?.totalMs);
});

/// Ventanas largas: se arman con `user_stats_monthly` porque el historial
/// crudo se poda a los 90 días. Una sola petición trae todos los meses, así
/// que el periodo anterior sale de las mismas filas, sin pedir nada más.
Future<StatsSnapshot> _monthlySnapshot(
  SupabaseStatsRepository repo,
  StatsPeriod period,
  DateTime now,
) async {
  final allRows = await repo.fetchMonthlyStats();
  if (allRows.isEmpty) return const StatsSnapshot();

  final rows = StatsCalculator.filterMonths(allRows, period, now: now);
  final snapshot = StatsCalculator.rollupMonthlyRows(rows);

  final days = period.days;
  if (days == null) return snapshot; // "Todo" no tiene periodo anterior

  final start = period.startFrom(now)!;
  final prevStart = start.subtract(Duration(days: days));
  final prevRows = allRows.where((r) =>
      !r.monthStart.isBefore(DateTime(prevStart.year, prevStart.month)) &&
      r.monthStart.isBefore(DateTime(start.year, start.month)));
  if (prevRows.isEmpty) return snapshot;

  return snapshot.copyWith(
    previousTotalMs: prevRows.fold<int>(0, (sum, r) => sum + r.totalMs),
  );
}

/// Modo local: el mismo cálculo, sobre Drift, reactivo.
Stream<StatsSnapshot> _localSnapshots(Ref ref, StatsPeriod period, DateTime now) {
  final dao = ref.watch(listeningHistoryDaoProvider);
  final start = period.startFrom(now) ?? DateTime.fromMillisecondsSinceEpoch(0);
  final days = period.days;
  // Para poder calcular la comparativa hace falta traer también el periodo
  // anterior, así que se lee desde el doble de atrás y se parte en dos.
  final readFrom = days == null ? start : start.subtract(Duration(days: days));

  return dao.watchEntriesSince(readFrom).map((rows) {
    final entries = rows
        .map((e) => RawListenEntry(
              artistId: e.artistId,
              trackId: e.trackId,
              albumId: e.albumId,
              genre: e.genre,
              durationListenedMs: e.durationListenedMs,
              listenedAt: e.listenedAt,
            ))
        .toList();

    final current = entries.where((e) => !e.listenedAt.isBefore(start)).toList();
    final snapshot = StatsCalculator.fromRawEntries(current, bucket: period.bucket);

    if (days == null) return snapshot;
    final previous = entries.where((e) => e.listenedAt.isBefore(start));
    if (previous.isEmpty) return snapshot;
    return snapshot.copyWith(
      previousTotalMs: previous.fold<int>(0, (sum, e) => sum + e.durationListenedMs),
    );
  });
}

/// Atajo para la tarjeta resumida de Inicio (7.G.6): siempre la semana.
final weeklyStatsProvider = Provider<AsyncValue<StatsSnapshot>>((ref) {
  return ref.watch(statsSnapshotProvider(StatsPeriod.week));
});

// ----------------------------------------------------------------------
// Resolución de nombre/portada de los ids que salen del cálculo
// ----------------------------------------------------------------------

class EnrichedArtist {
  final StatEntry entry;
  final DeezerArtist artist;

  const EnrichedArtist({required this.entry, required this.artist});
}

class EnrichedTrack {
  final StatEntry entry;
  final DeezerTrack track;

  const EnrichedTrack({required this.entry, required this.track});
}

/// Clave estable de los providers de metadata: los ids separados por comas.
///
/// **No usar una `List` como clave de un `family`.** Riverpod compara las
/// claves con `==`, y en Dart una lista compara por IDENTIDAD, no por
/// contenido. Como la pantalla construye la lista con `.take(n).toList()` en
/// cada `build`, cada reconstrucción creaba un provider NUEVO que empezaba a
/// cargar de cero: los tops se quedaban en "cargando" para siempre, se
/// repetían las peticiones a Deezer y se acumulaban instancias de provider
/// que nadie liberaba — la causa de que la lista de artistas y canciones
/// apareciera vacía y de que la pantalla fuera lenta en móvil.
String statsIdsKey(Iterable<StatEntry> entries) => entries.map((e) => e.id).join(',');

/// Nombre/portada por id de artista, resueltos en paralelo y descartando en
/// silencio los que fallen (mismo patrón que `personalizedSectionsProvider`):
/// un id roto no debe tumbar la pantalla.
///
/// Consulta primero [StatsMetadataCacheDao] (Drift local) y solo golpea
/// Deezer para lo que no esté cacheado. Nombre y portada no cambian lo
/// bastante como para justificar un TTL.
///
/// `autoDispose` para que cambiar de periodo o plegar un top no deje viva la
/// consulta anterior.
final artistMetaProvider =
    FutureProvider.autoDispose.family<Map<int, DeezerArtist>, String>((ref, idsKey) async {
  final ids = _parseIds(idsKey);
  if (ids.isEmpty) return const {};

  final deezerApi = ref.watch(deezerApiProvider);
  final cacheDao = ref.watch(statsMetadataCacheDaoProvider);
  final cached = await cacheDao.getMany(StatsEntityType.artist, ids.toSet());

  final results = await Future.wait(ids.map((id) async {
    final hit = cached[id];
    if (hit != null) {
      return MapEntry(
        id,
        DeezerArtist(id: id, name: hit.primaryName, pictureUrl: hit.coverUrl, nbFan: 0),
      );
    }
    try {
      final artist = await deezerApi.getArtist(id);
      await cacheDao.upsert(
        entityType: StatsEntityType.artist,
        entityId: id,
        primaryName: artist.name,
        coverUrl: artist.pictureUrl,
      );
      return MapEntry(id, artist);
    } catch (_) {
      return null;
    }
  }));

  return {for (final e in results.whereType<MapEntry<int, DeezerArtist>>()) e.key: e.value};
});

final trackMetaProvider =
    FutureProvider.autoDispose.family<Map<int, DeezerTrack>, String>((ref, idsKey) async {
  final ids = _parseIds(idsKey);
  if (ids.isEmpty) return const {};

  final deezerApi = ref.watch(deezerApiProvider);
  final cacheDao = ref.watch(statsMetadataCacheDaoProvider);
  final cached = await cacheDao.getMany(StatsEntityType.track, ids.toSet());

  final results = await Future.wait(ids.map((id) async {
    final hit = cached[id];
    if (hit != null) {
      return MapEntry(
        id,
        DeezerTrack(
          id: id,
          title: hit.primaryName,
          artistName: hit.secondaryName ?? '',
          artistId: 0,
          albumTitle: '',
          albumId: 0,
          coverUrl: hit.coverUrl,
          durationSec: 0,
        ),
      );
    }
    try {
      final track = await deezerApi.getTrack(id);
      await cacheDao.upsert(
        entityType: StatsEntityType.track,
        entityId: id,
        primaryName: track.title,
        secondaryName: track.artistName,
        coverUrl: track.coverUrl,
      );
      return MapEntry(id, track);
    } catch (_) {
      return null;
    }
  }));

  return {for (final e in results.whereType<MapEntry<int, DeezerTrack>>()) e.key: e.value};
});

List<int> _parseIds(String key) => key.isEmpty
    ? const []
    : key.split(',').map(int.tryParse).whereType<int>().toList();

/// Une los tops con su metadata, conservando el orden del top y dejando
/// fuera los ids que no se pudieron resolver.
List<EnrichedArtist> zipArtists(List<StatEntry> entries, Map<int, DeezerArtist> meta) => [
      for (final e in entries)
        if (meta[e.id] case final a?) EnrichedArtist(entry: e, artist: a),
    ];

List<EnrichedTrack> zipTracks(List<StatEntry> entries, Map<int, DeezerTrack> meta) => [
      for (final e in entries)
        if (meta[e.id] case final t?) EnrichedTrack(entry: e, track: t),
    ];
