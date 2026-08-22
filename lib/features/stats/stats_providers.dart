import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/apis/deezer_provider.dart';
import '../../data/local_db/database_provider.dart';
import '../../data/models/deezer/deezer_artist.dart';
import '../../data/models/deezer/deezer_track.dart';
import '../../data/supabase/supabase_stats_repository.dart';
import 'stats_calculator.dart';

final supabaseStatsRepositoryProvider = Provider<SupabaseStatsRepository>((ref) {
  return SupabaseStatsRepository();
});

/// Fase 7.G.3: Semanal, sobre datos crudos de `listening_history`
/// (últimos 7 días), disponible con o sin cuenta (7.I.6).
final weeklyStatsProvider = FutureProvider<StatsSnapshot>((ref) async {
  final dao = ref.watch(listeningHistoryDaoProvider);
  final entries = await dao.getEntriesSince(weekCutoff(DateTime.now()));
  return StatsCalculator.fromRawEntries(
    entries
        .map((e) => RawListenEntry(
              artistId: e.artistId,
              trackId: e.trackId,
              genre: e.genre,
              durationListenedMs: e.durationListenedMs,
            ))
        .toList(),
    topN: 5,
  );
});

/// Fase 7.G.3: Mensual, sobre datos crudos (últimos 30 días) -- no confundir
/// con `user_stats_monthly` (D-17): esa tabla guarda meses YA cerrados, acá
/// se necesita el mes en curso.
final monthlyStatsProvider = FutureProvider<StatsSnapshot>((ref) async {
  final dao = ref.watch(listeningHistoryDaoProvider);
  final entries = await dao.getEntriesSince(monthCutoff(DateTime.now()));
  return StatsCalculator.fromRawEntries(
    entries
        .map((e) => RawListenEntry(
              artistId: e.artistId,
              trackId: e.trackId,
              genre: e.genre,
              durationListenedMs: e.durationListenedMs,
            ))
        .toList(),
    topN: 10,
  );
});

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
/// de [StatsCalculator] contra la API de Deezer, en paralelo, descartando en
/// silencio los IDs que fallen (mismo patrón que `personalizedSectionsProvider`)
/// -- un solo ID roto no debe tumbar toda la pantalla de Estadísticas.
final enrichedArtistsProvider =
    FutureProvider.family<List<EnrichedArtist>, List<StatEntry>>((ref, entries) async {
  final deezerApi = ref.watch(deezerApiProvider);
  final results = await Future.wait(entries.map((entry) async {
    try {
      final artist = await deezerApi.getArtist(entry.id);
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
  final results = await Future.wait(entries.map((entry) async {
    try {
      final track = await deezerApi.getTrack(entry.id);
      return EnrichedTrack(entry: entry, track: track);
    } catch (_) {
      return null;
    }
  }));
  return results.whereType<EnrichedTrack>().toList();
});
