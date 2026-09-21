import 'stats_models.dart';

/// Agregación pura de estadísticas de escucha, sin Drift, Riverpod ni
/// Supabase detrás (mismo patrón que `computeCanEdit`/`computeAuthRedirect`):
/// se puede probar con listas en memoria.
///
/// Es el espejo en Dart del RPC `get_listening_stats`. Existen los dos porque
/// con cuenta el cálculo se hace en Postgres (una petición de ~5 KB en vez de
/// bajar miles de filas, H-S5) y en modo local no hay servidor al que
/// preguntarle. Los dos tienen que dar el mismo resultado sobre los mismos
/// datos, y hay tests que comparan ambos caminos.

/// Entrada cruda de `listening_history`, ya filtrada por ventana.
class RawListenEntry {
  final int artistId;
  final int trackId;
  final int albumId;
  final String? genre;
  final int durationListenedMs;
  final DateTime listenedAt;

  const RawListenEntry({
    required this.artistId,
    required this.trackId,
    required this.durationListenedMs,
    required this.listenedAt,
    this.albumId = 0,
    this.genre,
  });
}

/// Fila de `user_stats_monthly` ya parseada.
class MonthlyStatsRow {
  final DateTime monthStart;
  final int totalMs;
  final int totalPlays;
  final List<StatEntry> topArtists;
  final List<StatEntry> topTracks;
  final List<StatEntry> topAlbums;
  final List<GenreEntry> topGenres;
  final List<HourCell> hours;

  const MonthlyStatsRow({
    required this.monthStart,
    required this.totalMs,
    this.totalPlays = 0,
    this.topArtists = const [],
    this.topTracks = const [],
    this.topAlbums = const [],
    this.topGenres = const [],
    this.hours = const [],
  });
}

abstract class StatsCalculator {
  /// Calcula un snapshot completo sobre entradas crudas (camino de modo
  /// local, y también el que usan los tests para contrastar contra el RPC).
  static StatsSnapshot fromRawEntries(
    List<RawListenEntry> entries, {
    required StatsBucket bucket,
    int topN = 25,
  }) {
    final artists = <int, StatEntry>{};
    final tracks = <int, StatEntry>{};
    final albums = <int, StatEntry>{};
    final genres = <String, GenreEntry>{};
    final series = <DateTime, SeriesPoint>{};
    final hours = <int, HourCell>{};
    final days = <DateTime>{};
    var totalMs = 0;

    for (final e in entries) {
      final ms = e.durationListenedMs;
      totalMs += ms;

      if (e.artistId > 0) {
        artists[e.artistId] =
            (artists[e.artistId] ?? StatEntry(id: e.artistId, ms: 0)).merge(
          StatEntry(id: e.artistId, ms: ms, plays: 1),
        );
      }
      if (e.trackId > 0) {
        tracks[e.trackId] = (tracks[e.trackId] ?? StatEntry(id: e.trackId, ms: 0)).merge(
          StatEntry(id: e.trackId, ms: ms, plays: 1),
        );
      }
      if (e.albumId > 0) {
        albums[e.albumId] = (albums[e.albumId] ?? StatEntry(id: e.albumId, ms: 0)).merge(
          StatEntry(id: e.albumId, ms: ms, plays: 1),
        );
      }
      final g = e.genre;
      if (g != null && g.isNotEmpty) {
        genres[g] = (genres[g] ?? GenreEntry(genre: g, ms: 0)).merge(
          GenreEntry(genre: g, ms: ms, plays: 1),
        );
      }

      final at = e.listenedAt;
      final b = truncateTo(at, bucket);
      final prev = series[b];
      series[b] = SeriesPoint(
        t: b,
        ms: (prev?.ms ?? 0) + ms,
        plays: (prev?.plays ?? 0) + 1,
      );

      // `DateTime.weekday` va de 1 (lunes) a 7 (domingo); Postgres
      // `EXTRACT(dow)` usa 0 = domingo. Se normaliza al criterio de Postgres
      // para que los dos caminos produzcan el mismo dato.
      final dow = at.weekday % 7;
      final key = dow * 24 + at.hour;
      hours[key] = HourCell(dow: dow, hour: at.hour, ms: (hours[key]?.ms ?? 0) + ms);
      days.add(DateTime(at.year, at.month, at.day));
    }

    return StatsSnapshot(
      totalMs: totalMs,
      totalPlays: entries.length,
      distinctArtists: artists.length,
      distinctTracks: tracks.length,
      distinctAlbums: albums.length,
      activeDays: days.length,
      topArtists: _topEntries(artists.values, topN),
      topTracks: _topEntries(tracks.values, topN),
      topAlbums: _topEntries(albums.values, topN),
      topGenres: _topGenres(genres.values, topN),
      series: series.values.toList()..sort((a, b) => a.t.compareTo(b.t)),
      hours: hours.values.toList(),
    );
  }

  /// Consolida filas mensuales en un único snapshot (ventanas de 6/12 meses
  /// y "Todo").
  ///
  /// Los totales salen exactos porque cada fila guarda su total real; los
  /// tops son aproximados porque cada mes solo conserva sus 30 mejores, y por
  /// eso el snapshot sale marcado con [StatsSnapshot.topsAreApproximate].
  static StatsSnapshot rollupMonthlyRows(List<MonthlyStatsRow> rows, {int topN = 25}) {
    final artists = <int, StatEntry>{};
    final tracks = <int, StatEntry>{};
    final albums = <int, StatEntry>{};
    final genres = <String, GenreEntry>{};
    final hours = <int, HourCell>{};
    final series = <SeriesPoint>[];
    var totalMs = 0;
    var totalPlays = 0;

    for (final row in rows) {
      totalMs += row.totalMs;
      totalPlays += row.totalPlays;
      series.add(SeriesPoint(t: row.monthStart, ms: row.totalMs, plays: row.totalPlays));

      for (final a in row.topArtists) {
        artists[a.id] = (artists[a.id] ?? StatEntry(id: a.id, ms: 0)).merge(a);
      }
      for (final t in row.topTracks) {
        tracks[t.id] = (tracks[t.id] ?? StatEntry(id: t.id, ms: 0)).merge(t);
      }
      for (final al in row.topAlbums) {
        albums[al.id] = (albums[al.id] ?? StatEntry(id: al.id, ms: 0)).merge(al);
      }
      for (final g in row.topGenres) {
        genres[g.genre] = (genres[g.genre] ?? GenreEntry(genre: g.genre, ms: 0)).merge(g);
      }
      for (final h in row.hours) {
        final key = h.dow * 24 + h.hour;
        hours[key] = HourCell(dow: h.dow, hour: h.hour, ms: (hours[key]?.ms ?? 0) + h.ms);
      }
    }

    series.sort((a, b) => a.t.compareTo(b.t));

    return StatsSnapshot(
      totalMs: totalMs,
      totalPlays: totalPlays,
      distinctArtists: artists.length,
      distinctTracks: tracks.length,
      distinctAlbums: albums.length,
      activeDays: 0, // no se puede derivar de un agregado mensual
      topArtists: _topEntries(artists.values, topN),
      topTracks: _topEntries(tracks.values, topN),
      topAlbums: _topEntries(albums.values, topN),
      topGenres: _topGenres(genres.values, topN),
      series: series,
      hours: hours.values.toList(),
      topsAreApproximate: true,
    );
  }

  /// Recorta [rows] a los meses que caen dentro de la ventana de [period].
  static List<MonthlyStatsRow> filterMonths(List<MonthlyStatsRow> rows, StatsPeriod period,
      {DateTime? now}) {
    final start = period.startFrom(now ?? DateTime.now());
    if (start == null) return rows;
    final firstMonth = DateTime(start.year, start.month);
    return rows.where((r) => !r.monthStart.isBefore(firstMonth)).toList();
  }

  /// Mismo criterio que `date_trunc` de Postgres. Las semanas empiezan en
  /// lunes, como en Postgres (no en domingo).
  static DateTime truncateTo(DateTime at, StatsBucket bucket) => switch (bucket) {
        StatsBucket.day => DateTime(at.year, at.month, at.day),
        StatsBucket.week =>
          DateTime(at.year, at.month, at.day).subtract(Duration(days: at.weekday - 1)),
        StatsBucket.month => DateTime(at.year, at.month),
      };

  static List<StatEntry> _topEntries(Iterable<StatEntry> values, int topN) {
    final sorted = values.toList()..sort((a, b) => b.ms.compareTo(a.ms));
    return sorted.take(topN).toList();
  }

  static List<GenreEntry> _topGenres(Iterable<GenreEntry> values, int topN) {
    final sorted = values.toList()..sort((a, b) => b.ms.compareTo(a.ms));
    return sorted.take(topN).toList();
  }
}

DateTime truncateTo(DateTime at, StatsBucket bucket) => StatsCalculator.truncateTo(at, bucket);
