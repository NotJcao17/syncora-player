import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_playlist_repository.dart';

class SupabaseAlbumRepository {
  bool get _isTestEnv => Platform.environment.containsKey('FLUTTER_TEST');

  SupabaseClient? get _client {
    if (_isTestEnv) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> fetchSavedAlbums() async {
    final client = _client;
    if (client == null) return [];
    final userId = client.auth.currentUser?.id;
    if (userId == null) return [];

    // Por páginas, como las pistas de una playlist: con más de 1000 álbumes
    // (`max_rows` de Supabase) el sync podaba en local los que no llegaban.
    return SupabasePlaylistRepository.fetchAllPages((from, to) async {
      final response = await client
          .from('saved_albums')
          .select()
          .eq('user_id', userId)
          .order('added_at', ascending: false)
          .order('id', ascending: true)
          .range(from, to);
      return List<Map<String, dynamic>>.from(response);
    });
  }

  Future<void> saveAlbum(Map<String, dynamic> albumData) async {
    final client = _client;
    if (client == null) return;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    final payload = {
      ...albumData,
      'user_id': userId,
    };

    await client.from('saved_albums').upsert(
      payload,
      onConflict: 'user_id,album_id',
    );
  }

  Future<void> removeAlbum(int albumId) async {
    final client = _client;
    if (client == null) return;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    await client
        .from('saved_albums')
        .delete()
        .eq('user_id', userId)
        .eq('album_id', albumId);
  }
}
