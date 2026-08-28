import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/apis/deezer_provider.dart';
import '../../data/local_db/daos/stats_metadata_cache_dao.dart';
import '../../data/local_db/database_provider.dart';
import '../../data/models/deezer/deezer_artist.dart';
import '../../data/models/deezer/deezer_track.dart';
import '../../data/supabase/supabase_stats_repository.dart';
import '../auth/local_mode_provider.dart';
import 'stats_calculator.dart';

final supabaseStatsRepositoryProvider = Provider<SupabaseStatsRepository>((ref) {
  return SupabaseStatsRepository();
});

/// Fase de polish post-7.G (hallazgo verificado): con cuenta, Semanal/
/// Mensual deben venir siempre de Supabase (fuente de verdad multi-
/// dispositivo, D-24) -- Drift local solo ve las escuchas registradas en
/// ESTE dispositivo. Solo en modo local (sin cuenta, 7.I.6) Drift es la
/// única fuente posible.
///
/// Fase 7.G.3: Semanal, sobre datos crudos de `listening_history` (últimos 7
/// días), disponible con o sin cuenta.
///
/// `StreamProvider` en vez de `FutureProvider` para el camino local (bug
/// real de pruebas manuales: no se actualizaba sola al escuchar canciones
/// nuevas) -- `watchEntriesSince` reemite cada vez que la tabla cambia. El
/// camino con cuenta usa `Stream.fromFuture` (un solo evento) sobre el mismo
/// tipo de provider para no bifurcar la interfaz que consume la UI
/// (`AsyncValue<StatsSnapshot>` en ambos casos) -- se refresca invalidando
/// el provider (botón "Actualizar" de `stats_screen.dart`), no reactivamente.
final weeklyStatsProvider = StreamProvider<StatsSnapshot>((ref) {
  return _statsStreamSince(ref, weekCutoff(DateTime.now()), topN: 5);
});

/// Fase 7.G.3: Mensual, sobre datos crudos (últimos 30 días) -- no confundir
/// con `user_stats_monthly` (D-17): esa tabla guarda meses YA cerrados, acá
/// se necesita el mes en curso.
final monthlyStatsProvider = StreamProvider<StatsSnapshot>((ref) {
  return _statsStreamSince(ref, monthCutoff(DateTime.now()), topN: 10);
});

Stream<StatsSnapshot> _statsStreamSince(Ref ref, DateTime cutoff, {required int topN}) {
  final isLocalMode = ref.watch(localModeProvider);

  if (isLocalMode) {
    final dao = ref.watch(listeningHistoryDaoProvider);
    return dao.watchEntriesSince(cutoff).map(
          (entries) => StatsCalculator.fromRawEntries(
            entries
                .map((e) => RawListenEntry(
                      artistId: e.artistId,
                      trackId: e.trackId,
                      genre: e.genre,
                      durationListenedMs: e.durationListenedMs,
                    ))
                .toList(),
            topN: topN,
          ),
        );
  }

  final repo = ref.watch(supabaseStatsRepositoryProvider);
  return Stream.fromFuture(
    repo.fetchEntriesSince(cutoff).then((entries) => StatsCalculator.fromRawEntries(entries, topN: topN)),
  );
}

/// Fase 7.G.4: Anual (D-18: ventana móvil de los últimos 12 meses, no un
/// corte de calendario), exclusiva de cuenta (7.I.6).
final yearlyStatsProvider = FutureProvider<StatsSnapshot>((ref) async {
  final repo = ref.watch(supabaseStatsRepositoryProvider);
  final rows = await repo.fetchMonthlyStats(limitMonths: 12);
  return StatsCalculator.rollupMonthlyRows(rows, topN: 10);
});

/// Fase 7.G.4/7.G.5: Desde el inicio -- bajo demanda (no autoload), toma
/// todas las filas de `user_stats_monthly` disponibles.
final allTimeStatsProvider = FutureProvider<StatsSnapshot>((ref) async {
  final repo = ref.watch(supabaseStatsRepositoryProvider);
  final rows = await repo.fetchMonthlyStats();
  return StatsCalculator.rollupMonthlyRows(rows, topN: 10);
});

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

/// Fase 7.G: resuelve nombre/portada de los IDs de artista/canción que salen
/// de [StatsCalculator], en paralelo, descartando en silencio los IDs que
/// fallen (mismo patrón que `personalizedSectionsProvider`) -- un solo ID
/// roto no debe tumbar toda la pantalla de Estadísticas.
///
/// Hallazgo verificado post-7.G (bundle de polish): antes golpeaba
/// `DeezerApi.getArtist`/`getTrack` en vivo para cada uno de los 10-20 ids de
/// la pantalla, cada vez que se abría o refrescaba -- causa del lag/
/// parpadeo de ~15s reportado. Ahora consulta primero
/// [StatsMetadataCacheDao] (Drift local, por id); solo golpea Deezer para
/// los ids que no estén cacheados, y guarda el resultado para la próxima vez.
/// Nombre/portada de un artista o canción no cambian con la frecuencia
/// suficiente como para no cachearlos indefinidamente (sin TTL).
final enrichedArtistsProvider =
    FutureProvider.family<List<EnrichedArtist>, List<StatEntry>>((ref, entries) async {
  final deezerApi = ref.watch(deezerApiProvider);
  final cacheDao = ref.watch(statsMetadataCacheDaoProvider);
  final cached = await cacheDao.getMany(StatsEntityType.artist, entries.map((e) => e.id).toSet());

  final results = await Future.wait(entries.map((entry) async {
    final hit = cached[entry.id];
    if (hit != null) {
      return EnrichedArtist(
        entry: entry,
        artist: DeezerArtist(id: entry.id, name: hit.primaryName, pictureUrl: hit.coverUrl, nbFan: 0),
      );
    }
    try {
      final artist = await deezerApi.getArtist(entry.id);
      await cacheDao.upsert(
        entityType: StatsEntityType.artist,
        entityId: entry.id,
        primaryName: artist.name,
        coverUrl: artist.pictureUrl,
      );
      return EnrichedArtist(entry: entry, artist: artist);
    } catch (_) {
      return null;
    }
  }));
  return results.whereType<EnrichedArtist>().toList();
});

final enrichedTracksProvider =
    FutureProvider.family<List<EnrichedTrack>, List<StatEntry>>((ref, entries) async {
  final deezerApi = ref.watch(deezerApiProvider);
  final cacheDao = ref.watch(statsMetadataCacheDaoProvider);
  final cached = await cacheDao.getMany(StatsEntityType.track, entries.map((e) => e.id).toSet());

  final results = await Future.wait(entries.map((entry) async {
    final hit = cached[entry.id];
    if (hit != null) {
      return EnrichedTrack(
        entry: entry,
        track: DeezerTrack(
          id: entry.id,
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
      final track = await deezerApi.getTrack(entry.id);
      await cacheDao.upsert(
        entityType: StatsEntityType.track,
        entityId: entry.id,
        primaryName: track.title,
        secondaryName: track.artistName,
        coverUrl: track.coverUrl,
      );
      return EnrichedTrack(entry: entry, track: track);
    } catch (_) {
      return null;
    }
  }));
  return results.whereType<EnrichedTrack>().toList();
});
