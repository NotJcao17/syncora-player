import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabasePlaylistRepository {
  bool get _isTestEnv => Platform.environment.containsKey('FLUTTER_TEST');

  SupabaseClient? get _client {
    if (_isTestEnv) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> fetchUserPlaylists() async {
    final client = _client;
    if (client == null) return [];
    final userId = client.auth.currentUser?.id;
    if (userId == null) return [];

    final response = await client
        .from('playlists')
        .select()
        .eq('user_id', userId)
        .order('order_index', ascending: true);

    return List<Map<String, dynamic>>.from(response);
  }

  Future<List<Map<String, dynamic>>> fetchPlaylistTracks(String playlistId) async {
    final client = _client;
    if (client == null) return [];
    final response = await client
        .from('playlist_tracks')
        .select()
        .eq('playlist_id', playlistId)
        .order('order_index', ascending: true);

    return List<Map<String, dynamic>>.from(response);
  }

  Future<Map<String, dynamic>> createPlaylist({
    required String title,
    String? description,
    bool isPublic = false,
  }) async {
    final client = _client;
    if (client == null) return {};
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      return {};
    }

    final response = await client.from('playlists').insert({
      'user_id': userId,
      'title': title,
      'description': description,
      'is_public': isPublic,
    }).select().single();

    return response;
  }

  Future<void> updatePlaylist(
    String id, {
    String? title,
    String? description,
    bool? isPublic,
    bool? isPinned,
    int? orderIndex,
  }) async {
    final client = _client;
    if (client == null) return;

    final updates = <String, dynamic>{
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (title != null) updates['title'] = title;
    if (description != null) updates['description'] = description;
    if (isPublic != null) updates['is_public'] = isPublic;
    if (isPinned != null) updates['is_pinned'] = isPinned;
    if (orderIndex != null) updates['order_index'] = orderIndex;

    await client.from('playlists').update(updates).eq('id', id);
  }

  Future<void> deletePlaylist(String id) async {
    final client = _client;
    if (client == null) return;
    await client.from('playlists').delete().eq('id', id);
  }

  Future<void> addTrackToPlaylist(
    String playlistId,
    Map<String, dynamic> trackData,
  ) async {
    final client = _client;
    if (client == null) return;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    final payload = {
      ...trackData,
      'playlist_id': playlistId,
      'user_id': userId,
    };

    await client.from('playlist_tracks').insert(payload);
  }

  Future<void> removeTrackFromPlaylist(String trackId) async {
    final client = _client;
    if (client == null) return;
    await client.from('playlist_tracks').delete().eq('id', trackId);
  }

  Future<void> reorderTracks(
    String playlistId,
    List<String> trackIdsInOrder,
  ) async {
    final client = _client;
    if (client == null) return;
    for (int i = 0; i < trackIdsInOrder.length; i++) {
      await client
          .from('playlist_tracks')
          .update({'order_index': i})
          .eq('id', trackIdsInOrder[i])
          .eq('playlist_id', playlistId);
    }
  }
}
