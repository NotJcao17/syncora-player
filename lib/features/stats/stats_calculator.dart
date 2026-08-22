/// Fase 7.G.3/7.G.4 -- agregación pura de estadísticas de escucha, sin
/// dependencias de Drift/Riverpod/Supabase (mismo patrón que
/// `computeCanEdit`/`computeAuthRedirect`): testeable con listas en memoria.
class StatEntry {
  final int id;
  final int minutes;
  final int playCount;

  const StatEntry({required this.id, required this.minutes, this.playCount = 0});
}

class GenreEntry {
  final String genre;
  final int minutes;

  const GenreEntry({required this.genre, required this.minutes});
}

class StatsSnapshot {
  final int totalMinutes;
  final List<StatEntry> topArtists;
  final List<StatEntry> topTracks;
  final List<GenreEntry> topGenres;
  final DateTime? mostActiveMonth;

  const StatsSnapshot({
    required this.totalMinutes,
    required this.topArtists,
    required this.topTracks,
    required this.topGenres,
    this.mostActiveMonth,
  });

  bool get isEmpty => totalMinutes == 0 && topArtists.isEmpty && topTracks.isEmpty;
}

/// Entrada cruda de `listening_history`, ya filtrada por ventana de fecha
/// por quien llama (el DAO o el rollup mensual).
class RawListenEntry {
  final int artistId;
  final int trackId;
  final String? genre;
  final int durationListenedMs;

  const RawListenEntry({
    required this.artistId,
    required this.trackId,
    required this.durationListenedMs,
    this.genre,
  });
}

/// Fila ya traída de `user_stats_monthly` (top 50 de artistas/canciones/
/// géneros por mes, ya parseados del JSONB).
class MonthlyStatsRow {
  final DateTime monthStart;
  final int totalMinutes;
  final List<StatEntry> topArtists;
  final List<StatEntry> topTracks;
  final List<GenreEntry> topGenres;

  const MonthlyStatsRow({
    required this.monthStart,
    required this.totalMinutes,
    required this.topArtists,
    required this.topTracks,
    required this.topGenres,
  });
}

DateTime weekCutoff(DateTime now) => now.subtract(const Duration(days: 7));

DateTime monthCutoff(DateTime now) => now.subtract(const Duration(days: 30));

abstract class StatsCalculator {
  /// Alimenta Semanal (topN=5, sin géneros) y Mensual (topN=10, con
  /// géneros) -- mismo método, distinta ventana/topN, según quien llame.
  static StatsSnapshot fromRawEntries(List<RawListenEntry> entries, {int topN = 5}) {
    final artistMinutes = <int, int>{};
    final artistPlays = <int, int>{};
    final trackMinutes = <int, int>{};
    final trackPlays = <int, int>{};
    final genreMinutes = <String, int>{};
    var totalMs = 0;

    for (final entry in entries) {
      totalMs += entry.durationListenedMs;
      final minutes = entry.durationListenedMs ~/ 60000;

      if (entry.artistId > 0) {
        artistMinutes[entry.artistId] = (artistMinutes[entry.artistId] ?? 0) + minutes;
        artistPlays[entry.artistId] = (artistPlays[entry.artistId] ?? 0) + 1;
      }
      if (entry.trackId > 0) {
        trackMinutes[entry.trackId] = (trackMinutes[entry.trackId] ?? 0) + minutes;
        trackPlays[entry.trackId] = (trackPlays[entry.trackId] ?? 0) + 1;
      }
      final genre = entry.genre;
      if (genre != null && genre.isNotEmpty) {
        genreMinutes[genre] = (genreMinutes[genre] ?? 0) + minutes;
      }
    }

    return StatsSnapshot(
      totalMinutes: totalMs ~/ 60000,
      topArtists: _topStatEntries(artistMinutes, artistPlays, topN),
      topTracks: _topStatEntries(trackMinutes, trackPlays, topN),
      topGenres: _topGenreEntries(genreMinutes),
    );
  }

  /// Suma (merge por id) las filas de `user_stats_monthly` para producir un
  /// único snapshot -- sirve tanto para Anual (últimas 12 filas) como
  /// Desde el inicio (todas). `mostActiveMonth` es la fila individual de
  /// mayor `totalMinutes`, no una suma.
  static StatsSnapshot rollupMonthlyRows(List<MonthlyStatsRow> rows, {int topN = 10}) {
    final artistMinutes = <int, int>{};
    final trackMinutes = <int, int>{};
    final genreMinutes = <String, int>{};
    var totalMinutes = 0;
    MonthlyStatsRow? mostActive;

    for (final row in rows) {
      totalMinutes += row.totalMinutes;
      if (mostActive == null || row.totalMinutes > mostActive.totalMinutes) {
        mostActive = row;
      }
      for (final a in row.topArtists) {
        artistMinutes[a.id] = (artistMinutes[a.id] ?? 0) + a.minutes;
      }
      for (final t in row.topTracks) {
        trackMinutes[t.id] = (trackMinutes[t.id] ?? 0) + t.minutes;
      }
      for (final g in row.topGenres) {
        genreMinutes[g.genre] = (genreMinutes[g.genre] ?? 0) + g.minutes;
      }
    }

    return StatsSnapshot(
      totalMinutes: totalMinutes,
      topArtists: _topStatEntries(artistMinutes, const {}, topN),
      topTracks: _topStatEntries(trackMinutes, const {}, topN),
      topGenres: _topGenreEntries(genreMinutes),
      mostActiveMonth: mostActive?.monthStart,
    );
  }

  static List<StatEntry> _topStatEntries(Map<int, int> minutes, Map<int, int> plays, int topN) {
    final sorted = minutes.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return sorted
        .take(topN)
        .map((e) => StatEntry(id: e.key, minutes: e.value, playCount: plays[e.key] ?? 0))
        .toList();
  }

  static List<GenreEntry> _topGenreEntries(Map<String, int> minutes) {
    final sorted = minutes.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return sorted.map((e) => GenreEntry(genre: e.key, minutes: e.value)).toList();
  }
}
