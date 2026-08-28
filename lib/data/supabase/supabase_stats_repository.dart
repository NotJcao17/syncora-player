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

  /// Fase de polish post-7.G (hallazgo verificado, no estaba en el plan
  /// original): Semanal/Mensual leían siempre de Drift local
  /// (`listeningHistoryDaoProvider`), incluso con cuenta -- correcto para
  /// modo local, pero incorrecto con cuenta: Drift solo ve las escuchas de
  /// ESTE dispositivo, no las de otros dispositivos de la misma cuenta.
  /// `stats_providers.dart` usa este método (no Drift) cuando hay sesión.
  Future<List<RawListenEntry>> fetchEntriesSince(DateTime cutoff) async {
    final client = _client;
    if (client == null) return [];
    final userId = client.auth.currentUser?.id;
    if (userId == null) return [];

    final rows = await client
        .from('listening_history')
        .select('artist_id, track_id, genre, duration_listened_ms')
        .eq('user_id', userId)
        .gte('listened_at', cutoff.toUtc().toIso8601String());

    return (rows as List).map((row) {
      final map = row as Map<String, dynamic>;
      return RawListenEntry(
        artistId: map['artist_id'] as int? ?? 0,
        trackId: map['track_id'] as int? ?? 0,
        genre: map['genre'] as String?,
        durationListenedMs: map['duration_listened_ms'] as int? ?? 0,
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
