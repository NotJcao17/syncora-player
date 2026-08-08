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

  Future<void> insertListeningHistory({
    required int trackId,
    int? artistId,
    int? albumId,
    String? genre,
    int? durationListenedMs,
  }) async {
    final client = _client;
    if (client == null) return;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    await client.from('listening_history').insert({
      'user_id': userId,
      'track_id': trackId,
      'artist_id': artistId,
      'album_id': albumId,
      'genre': genre,
      'duration_listened_ms': durationListenedMs,
    });
  }
}
