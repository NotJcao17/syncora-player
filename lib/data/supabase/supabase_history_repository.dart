import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseHistoryRepository {
  bool get _isTestEnv => Platform.environment.containsKey('FLUTTER_TEST');

  SupabaseClient? get _client {
    if (_isTestEnv) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  /// Sube una entrada de historial de escucha. Usa `upsert` con una clave
  /// natural (`user_id, track_id, listened_at`, ver migración
  /// `20250001000007_listening_history_dedup.sql`) en vez de un `insert`
  /// plano: es la red de seguridad de la Fase 7.0.1 contra duplicados si el
  /// marcado local de `syncedAt` llega a fallar o una reinstalación reenvía
  /// filas ya subidas — `listenedAt` debe ser el valor fijo que ya trae la
  /// fila local (nunca `DateTime.now()` en cada intento), para que la clave
  /// natural sea estable entre reintentos.
  Future<void> insertListeningHistory({
    required int trackId,
    required DateTime listenedAt,
    int? artistId,
    int? albumId,
    String? genre,
    int? durationListenedMs,
  }) async {
    final client = _client;
    if (client == null) return;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    await client.from('listening_history').upsert(
      {
        'user_id': userId,
        'track_id': trackId,
        'artist_id': artistId,
        'album_id': albumId,
        'genre': genre,
        'duration_listened_ms': durationListenedMs,
        'listened_at': listenedAt.toUtc().toIso8601String(),
      },
      onConflict: 'user_id,track_id,listened_at',
    );
  }
}
