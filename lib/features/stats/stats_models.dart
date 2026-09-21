/// Modelo de datos de Estadísticas.
///
/// **Todo se guarda y se suma en milisegundos**, nunca en minutos. El modelo
/// anterior redondeaba con `ceil()` por cada artista y por cada canción,
/// mientras que el SQL hacía división entera: la suma de los minutos por
/// artista no daba el total mostrado, y el mismo mes cambiaba de número al
/// pasar de la vista "cruda" a la "agregada" (H-S7). Ahora se redondea una
/// sola vez, al pintar ([formatMinutes]).
library;

/// Agrupación temporal de la serie del gráfico. Coincide con los valores que
/// acepta `date_trunc` en el RPC `get_listening_stats`.
enum StatsBucket { day, week, month }

extension StatsBucketSql on StatsBucket {
  String get sql => switch (this) {
        StatsBucket.day => 'day',
        StatsBucket.week => 'week',
        StatsBucket.month => 'month',
      };
}

/// Ventana de tiempo que el usuario elige en el selector de la pantalla.
///
/// El corte en [usesMonthlyAggregate] no es estético: el historial crudo de
/// Supabase se poda a los 90 días (es lo que permite quedarse en el plan
/// free), así que solo las ventanas que caben ahí pueden calcularse exactas
/// desde `listening_history`. Las más largas se arman con
/// `user_stats_monthly`, donde los TOTALES son exactos pero los tops son
/// aproximados: se guardan los 30 mejores de cada mes, así que un artista
/// que queda siempre en el puesto 35 no aparece.
enum StatsPeriod {
  week,
  month,
  quarter,
  halfYear,
  year,
  allTime;

  String get label => switch (this) {
        StatsPeriod.week => '7 días',
        StatsPeriod.month => '30 días',
        StatsPeriod.quarter => '3 meses',
        StatsPeriod.halfYear => '6 meses',
        StatsPeriod.year => '12 meses',
        StatsPeriod.allTime => 'Todo',
      };

  /// Nombre largo, para títulos y tarjetas del Wrapped.
  String get longLabel => switch (this) {
        StatsPeriod.week => 'los últimos 7 días',
        StatsPeriod.month => 'los últimos 30 días',
        StatsPeriod.quarter => 'los últimos 3 meses',
        StatsPeriod.halfYear => 'los últimos 6 meses',
        StatsPeriod.year => 'los últimos 12 meses',
        StatsPeriod.allTime => 'todo tu historial',
      };

  /// Días que abarca la ventana, o `null` para "todo".
  int? get days => switch (this) {
        StatsPeriod.week => 7,
        StatsPeriod.month => 30,
        StatsPeriod.quarter => 90,
        StatsPeriod.halfYear => 183,
        StatsPeriod.year => 365,
        StatsPeriod.allTime => null,
      };

  /// ¿Hay que leer de `user_stats_monthly` en vez del historial crudo?
  ///
  /// 90 días es la retención del crudo. Se deja el trimestre en el lado
  /// crudo porque cae justo en el límite y así conserva tops exactos y serie
  /// semanal.
  bool get usesMonthlyAggregate => switch (this) {
        StatsPeriod.week || StatsPeriod.month || StatsPeriod.quarter => false,
        StatsPeriod.halfYear || StatsPeriod.year || StatsPeriod.allTime => true,
      };

  /// Agrupación de la serie del gráfico, elegida para que salgan entre ~6 y
  /// ~30 puntos: 7 días por día, 30 días por día, 3 meses por semana, y las
  /// ventanas largas por mes.
  StatsBucket get bucket => switch (this) {
        StatsPeriod.week || StatsPeriod.month => StatsBucket.day,
        StatsPeriod.quarter => StatsBucket.week,
        StatsPeriod.halfYear || StatsPeriod.year || StatsPeriod.allTime => StatsBucket.month,
      };

  /// Inicio de la ventana respecto a [now], o `null` para "todo".
  DateTime? startFrom(DateTime now) {
    final d = days;
    if (d == null) return null;
    final today = DateTime(now.year, now.month, now.day);
    // Inclusivo: "7 días" son hoy y los seis anteriores, no hoy y los siete
    // anteriores (que serían ocho puntos en el gráfico).
    return today.subtract(Duration(days: d - 1));
  }
}

/// Una entidad (artista, canción o álbum) dentro de un top.
class StatEntry {
  final int id;
  final int ms;
  final int plays;

  const StatEntry({required this.id, required this.ms, this.plays = 0});

  StatEntry merge(StatEntry other) =>
      StatEntry(id: id, ms: ms + other.ms, plays: plays + other.plays);

  @override
  bool operator ==(Object other) =>
      other is StatEntry && other.id == id && other.ms == ms && other.plays == plays;

  @override
  int get hashCode => Object.hash(id, ms, plays);
}

class GenreEntry {
  final String genre;
  final int ms;
  final int plays;

  const GenreEntry({required this.genre, required this.ms, this.plays = 0});

  GenreEntry merge(GenreEntry other) =>
      GenreEntry(genre: genre, ms: ms + other.ms, plays: plays + other.plays);

  @override
  bool operator ==(Object other) =>
      other is GenreEntry && other.genre == genre && other.ms == ms && other.plays == plays;

  @override
  int get hashCode => Object.hash(genre, ms, plays);
}

/// Un punto de la serie temporal del gráfico.
class SeriesPoint {
  final DateTime t;
  final int ms;
  final int plays;

  const SeriesPoint({required this.t, required this.ms, this.plays = 0});
}

/// Una celda del mapa de hábitos (día de la semana × hora).
///
/// [dow] sigue la convención de Postgres `EXTRACT(dow)`: 0 = domingo.
class HourCell {
  final int dow;
  final int hour;
  final int ms;

  const HourCell({required this.dow, required this.hour, required this.ms});
}

/// Todo lo que la pantalla necesita para un periodo.
class StatsSnapshot {
  final int totalMs;
  final int totalPlays;
  final int distinctArtists;
  final int distinctTracks;
  final int distinctAlbums;
  final int activeDays;
  final List<StatEntry> topArtists;
  final List<StatEntry> topTracks;
  final List<StatEntry> topAlbums;
  final List<GenreEntry> topGenres;
  final List<SeriesPoint> series;
  final List<HourCell> hours;

  /// Milisegundos del periodo INMEDIATAMENTE anterior, del mismo tamaño, o
  /// `null` si no se pudo calcular (p. ej. en "Todo", donde no hay anterior).
  /// Alimenta el "+18 % vs periodo anterior" de las tarjetas.
  final int? previousTotalMs;

  /// Los tops vienen de `user_stats_monthly`, que solo guarda los 30 mejores
  /// de cada mes: los totales son exactos, los tops aproximados. La pantalla
  /// lo dice en voz baja en vez de fingir precisión.
  final bool topsAreApproximate;

  const StatsSnapshot({
    this.totalMs = 0,
    this.totalPlays = 0,
    this.distinctArtists = 0,
    this.distinctTracks = 0,
    this.distinctAlbums = 0,
    this.activeDays = 0,
    this.topArtists = const [],
    this.topTracks = const [],
    this.topAlbums = const [],
    this.topGenres = const [],
    this.series = const [],
    this.hours = const [],
    this.previousTotalMs,
    this.topsAreApproximate = false,
  });

  bool get isEmpty => totalMs == 0 && totalPlays == 0;

  /// Variación respecto al periodo anterior, como fracción (0.18 = +18 %).
  /// `null` cuando no hay base de comparación con la que decir algo honesto.
  double? get trend {
    final prev = previousTotalMs;
    if (prev == null || prev == 0) return null;
    return (totalMs - prev) / prev;
  }

  StatsSnapshot copyWith({int? previousTotalMs, bool? topsAreApproximate}) => StatsSnapshot(
        totalMs: totalMs,
        totalPlays: totalPlays,
        distinctArtists: distinctArtists,
        distinctTracks: distinctTracks,
        distinctAlbums: distinctAlbums,
        activeDays: activeDays,
        topArtists: topArtists,
        topTracks: topTracks,
        topAlbums: topAlbums,
        topGenres: topGenres,
        series: series,
        hours: hours,
        previousTotalMs: previousTotalMs ?? this.previousTotalMs,
        topsAreApproximate: topsAreApproximate ?? this.topsAreApproximate,
      );
}

/// Minutos redondeados para mostrar. Único lugar donde se redondea (H-S7).
int msToMinutes(int ms) => (ms / 60000).round();

/// "3 h 42 min", "42 min", "< 1 min".
String formatListeningTime(int ms) {
  final totalMinutes = msToMinutes(ms);
  if (totalMinutes <= 0) return ms > 0 ? '< 1 min' : '0 min';
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours == 0) return '$minutes min';
  if (minutes == 0) return '$hours h';
  return '$hours h $minutes min';
}
