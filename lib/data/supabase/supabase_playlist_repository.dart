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
    bool isLiked = false,
  }) async {
    final client = _client;
    if (client == null) return {};
    final userId = client.auth.currentUser?.id;
    if (userId == null) return {};

    final response = await client.from('playlists').insert({
      'user_id': userId,
      'title': title,
      'description': description,
      'is_public': isPublic,
      'is_liked': isLiked,
    }).select().single();

    return response;
  }

  Future<Map<String, dynamic>> getOrCreateLikedPlaylist() async {
    final client = _client;
    if (client == null) return {};
    final userId = client.auth.currentUser?.id;
    if (userId == null) return {};

    try {
      final response = await client
          .from('playlists')
          .select()
          .eq('user_id', userId)
          .eq('is_liked', true);

      final list = List<Map<String, dynamic>>.from(response);
      if (list.isNotEmpty) {
        return list.first;
      }

      return await createPlaylist(
        title: 'Tus me gusta',
        isLiked: true,
      );
    } catch (_) {
      try {
        final recheck = await client
            .from('playlists')
            .select()
            .eq('user_id', userId)
            .eq('is_liked', true);
        final recheckList = List<Map<String, dynamic>>.from(recheck);
        if (recheckList.isNotEmpty) {
          return recheckList.first;
        }
      } catch (_) {}
      return {};
    }
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

  /// Variante en lote de [addTrackToPlaylist] — una sola petición para
  /// varias pistas, en vez de una por pista (usado al "promover" una
  /// playlist local-only a remota, donde puede haber decenas de pistas de
  /// golpe, ej. una importación CSV).
  Future<void> addTracksToPlaylist(
    String playlistId,
    List<Map<String, dynamic>> tracksData,
  ) async {
    if (tracksData.isEmpty) return;
    final client = _client;
    if (client == null) return;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    final payload = tracksData
        .map((t) => {...t, 'playlist_id': playlistId, 'user_id': userId})
        .toList();

    await client.from('playlist_tracks').insert(payload);
  }

  Future<void> removeTrackFromPlaylist(String playlistId, int trackId) async {
    final client = _client;
    if (client == null) return;
    await client
        .from('playlist_tracks')
        .delete()
        .eq('playlist_id', playlistId)
        .eq('track_id', trackId);
  }

  Future<void> reorderTracks(
    String playlistId,
    List<String> trackIdsInOrder,
  ) async {
    final client = _client;
    if (client == null) return;
    for (int i = 0; i < trackIdsInOrder.length; i++) {
      final tid = trackIdsInOrder[i];
      final parsedTrackId = int.tryParse(tid);
      if (parsedTrackId != null) {
        await client
            .from('playlist_tracks')
            .update({'order_index': i})
            .eq('playlist_id', playlistId)
            .eq('track_id', parsedTrackId);
      } else {
        await client
            .from('playlist_tracks')
            .update({'order_index': i})
            .eq('playlist_id', playlistId)
            .eq('id', tid);
      }
    }
  }
}
