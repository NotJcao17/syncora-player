import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../features/stats/stats_calculator.dart';

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

  /// Fase 7.G.4: filas de `user_stats_monthly` para el usuario actual, más
  /// recientes primero. `limitMonths: 12` para Anual (D-18: ventana móvil de
  /// los últimos 12 meses); sin límite para Desde el inicio. RLS ya filtra
  /// por `auth.uid()`, pero se filtra explícito también por claridad y para
  /// no depender solo de RLS.
  Future<List<MonthlyStatsRow>> fetchMonthlyStats({int? limitMonths}) async {
    final client = _client;
    if (client == null) return [];
    final userId = client.auth.currentUser?.id;
    if (userId == null) return [];

    var query = client
        .from('user_stats_monthly')
        .select('month_start, total_minutes, top_artists, top_tracks, top_genres')
        .eq('user_id', userId)
        .order('month_start', ascending: false);

    final rows = limitMonths != null ? await query.limit(limitMonths) : await query;

    return (rows as List).map((row) {
      final map = row as Map<String, dynamic>;
      return MonthlyStatsRow(
        monthStart: DateTime.parse(map['month_start'] as String),
        totalMinutes: map['total_minutes'] as int? ?? 0,
        topArtists: _parseEntries(map['top_artists']),
        topTracks: _parseEntries(map['top_tracks']),
        topGenres: _parseGenres(map['top_genres']),
      );
    }).toList();
  }

  List<StatEntry> _parseEntries(dynamic raw) {
    if (raw is! List) return [];
    return raw
        .map((e) => StatEntry(id: (e['id'] as num).toInt(), minutes: (e['minutes'] as num).toInt()))
        .toList();
  }

  List<GenreEntry> _parseGenres(dynamic raw) {
    if (raw is! List) return [];
    return raw
        .map((e) => GenreEntry(genre: e['genre'] as String, minutes: (e['minutes'] as num).toInt()))
        .toList();
  }
}
