import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/stats/stats_calculator.dart';
import '../../features/stats/stats_models.dart';

/// Lectura de estadísticas desde Supabase.
///
/// **Todo lo pesado se agrega en Postgres** (`get_listening_stats`), no acá.
/// La versión anterior bajaba las filas crudas y sumaba en Dart, con dos
/// problemas: PostgREST corta en 1000 filas por defecto y esa consulta no
/// pedía `limit` ni `order`, así que una ventana de 30 días de uso intenso
/// devolvía un subconjunto arbitrario sin avisar (H-S5); y en egress son
/// ~200 KB por carga frente a ~5 KB agregando en el servidor, que con 250
/// usuarios en el plan free es la diferencia entre >1 GB/mes y ~30 MB/mes.
class SupabaseStatsRepository {
  bool get _isTestEnv => Platform.environment.containsKey('FLUTTER_TEST');

  SupabaseClient? get _client {
    if (_isTestEnv) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  /// Snapshot de una ventana, calculado en Postgres.
  ///
  /// [from] inclusivo, [to] exclusivo. [tzOffsetMinutes] es el desfase local
  /// del dispositivo: los cortes por día/semana/mes tienen que caer en la
  /// medianoche del usuario, no en UTC, o la gráfica sale corrida un día.
  Future<StatsSnapshot?> fetchStats({
    required DateTime from,
    required DateTime to,
    required StatsBucket bucket,
    int topN = 25,
    int? tzOffsetMinutes,
  }) async {
    final client = _client;
    if (client == null) return null;
    if (client.auth.currentUser == null) return null;

    final raw = await client.rpc<dynamic>('get_listening_stats', params: {
      'p_from': from.toUtc().toIso8601String(),
      'p_to': to.toUtc().toIso8601String(),
      'p_bucket': bucket.sql,
      'p_top': topN,
      'p_tz_offset_minutes': tzOffsetMinutes ?? DateTime.now().timeZoneOffset.inMinutes,
    });

    if (raw is! Map) return null;
    return parseSnapshot(Map<String, dynamic>.from(raw));
  }

  /// Filas de `user_stats_monthly`, más recientes primero.
  Future<List<MonthlyStatsRow>> fetchMonthlyStats({int? limitMonths}) async {
    final client = _client;
    if (client == null) return [];
    final userId = client.auth.currentUser?.id;
    if (userId == null) return [];

    var query = client
        .from('user_stats_monthly')
        .select('month_start, total_ms, total_minutes, total_plays, '
            'top_artists, top_tracks, top_albums, top_genres, hour_histogram')
        .eq('user_id', userId)
        .order('month_start', ascending: false);

    final rows = limitMonths != null ? await query.limit(limitMonths) : await query;

    return (rows as List).map((row) {
      final map = Map<String, dynamic>.from(row as Map);
      // `total_ms` es la columna nueva; `total_minutes` queda como respaldo
      // para las filas que se escribieron antes de la migración 12.
      final totalMs = (map['total_ms'] as num?)?.toInt() ??
          ((map['total_minutes'] as num?)?.toInt() ?? 0) * 60000;
      return MonthlyStatsRow(
        monthStart: DateTime.parse(map['month_start'] as String),
        totalMs: totalMs,
        totalPlays: (map['total_plays'] as num?)?.toInt() ?? 0,
        topArtists: parseEntries(map['top_artists']),
        topTracks: parseEntries(map['top_tracks']),
        topAlbums: parseEntries(map['top_albums']),
        topGenres: parseGenres(map['top_genres']),
        hours: parseHours(map['hour_histogram']),
      );
    }).toList();
  }

  // --------------------------------------------------------------------
  // Parseo -- público y estático para poder probarlo con JSON de mesa, sin
  // red de por medio (el JSON real del RPC está copiado en los tests).
  // --------------------------------------------------------------------

  static StatsSnapshot parseSnapshot(Map<String, dynamic> json) => StatsSnapshot(
        totalMs: (json['total_ms'] as num?)?.toInt() ?? 0,
        totalPlays: (json['total_plays'] as num?)?.toInt() ?? 0,
        distinctArtists: (json['distinct_artists'] as num?)?.toInt() ?? 0,
        distinctTracks: (json['distinct_tracks'] as num?)?.toInt() ?? 0,
        distinctAlbums: (json['distinct_albums'] as num?)?.toInt() ?? 0,
        activeDays: (json['active_days'] as num?)?.toInt() ?? 0,
        topArtists: parseEntries(json['top_artists']),
        topTracks: parseEntries(json['top_tracks']),
        topAlbums: parseEntries(json['top_albums']),
        topGenres: parseGenres(json['top_genres']),
        series: parseSeries(json['series']),
        hours: parseHours(json['hours']),
      );

  static List<StatEntry> parseEntries(dynamic raw) {
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => StatEntry(
              id: (e['id'] as num?)?.toInt() ?? 0,
              // `ms` es lo que devuelve el RPC; `minutes` cubre las filas
              // mensuales viejas, escritas antes de la migración 12.
              ms: (e['ms'] as num?)?.toInt() ?? ((e['minutes'] as num?)?.toInt() ?? 0) * 60000,
              plays: (e['plays'] as num?)?.toInt() ?? 0,
            ))
        .where((e) => e.id > 0)
        .toList();
  }

  static List<GenreEntry> parseGenres(dynamic raw) {
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => GenreEntry(
              genre: e['genre'] as String? ?? '',
              ms: (e['ms'] as num?)?.toInt() ?? ((e['minutes'] as num?)?.toInt() ?? 0) * 60000,
              plays: (e['plays'] as num?)?.toInt() ?? 0,
            ))
        .where((e) => e.genre.isNotEmpty)
        .toList();
  }

  static List<SeriesPoint> parseSeries(dynamic raw) {
    if (raw is! List) return [];
    final points = raw
        .whereType<Map>()
        .map((e) {
          final t = DateTime.tryParse(e['t'] as String? ?? '');
          if (t == null) return null;
          return SeriesPoint(
            t: t,
            ms: (e['ms'] as num?)?.toInt() ?? 0,
            plays: (e['plays'] as num?)?.toInt() ?? 0,
          );
        })
        .whereType<SeriesPoint>()
        .toList();
    points.sort((a, b) => a.t.compareTo(b.t));
    return points;
  }

  static List<HourCell> parseHours(dynamic raw) {
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => HourCell(
              dow: (e['dow'] as num?)?.toInt() ?? 0,
              hour: (e['hour'] as num?)?.toInt() ?? 0,
              ms: (e['ms'] as num?)?.toInt() ?? 0,
            ))
        .toList();
  }
}
