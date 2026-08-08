import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../local_db/database_provider.dart';
import '../local_db/daos/listening_history_dao.dart';
import '../local_db/daos/playlist_dao.dart';
import '../local_db/daos/saved_album_dao.dart';
import '../local_db/syncora_database.dart';
import '../supabase/supabase_album_repository.dart';
import '../supabase/supabase_history_repository.dart';
import '../supabase/supabase_playlist_repository.dart';
import '../supabase/supabase_providers.dart';

class SyncService {
  final SupabasePlaylistRepository _playlistRepo;
  final SupabaseAlbumRepository _albumRepo;
  final SupabaseHistoryRepository _historyRepo;
  final PlaylistDao _playlistDao;
  final SavedAlbumDao _savedAlbumDao;
  final ListeningHistoryDao _listeningHistoryDao;

  SyncService({
    required SupabasePlaylistRepository playlistRepo,
    required SupabaseAlbumRepository albumRepo,
    required SupabaseHistoryRepository historyRepo,
    required PlaylistDao playlistDao,
    required SavedAlbumDao savedAlbumDao,
    required ListeningHistoryDao listeningHistoryDao,
  })  : _playlistRepo = playlistRepo, // ignore: prefer_initializing_formals
        _albumRepo = albumRepo, // ignore: prefer_initializing_formals
        _historyRepo = historyRepo, // ignore: prefer_initializing_formals
        _playlistDao = playlistDao, // ignore: prefer_initializing_formals
        _savedAlbumDao = savedAlbumDao, // ignore: prefer_initializing_formals
        _listeningHistoryDao = listeningHistoryDao; // ignore: prefer_initializing_formals

  bool get _isTestEnv => Platform.environment.containsKey('FLUTTER_TEST');

  Future<void> syncOnStartup() async {
    if (_isTestEnv) return;

    try {
      if (Supabase.instance.client.auth.currentUser == null) {
        return;
      }
    } catch (_) {
      return;
    }

    try {
      await _syncPlaylistsAndTracks();
      await _syncSavedAlbums();
      await _syncListeningHistory();
    } catch (_) {}
  }

  Future<void> _syncPlaylistsAndTracks() async {
    final remotePlaylists = await _playlistRepo.fetchUserPlaylists();
    final localPlaylists = await _playlistDao.getAllPlaylists();

    for (final remote in remotePlaylists) {
      final String remoteId = remote['id'].toString();
      final String title = remote['title'] as String? ?? 'Untitled';
      final String? description = remote['description'] as String?;
      final String? coverUrl = remote['cover_url'] as String?;
      final bool isLiked = remote['is_liked'] as bool? ?? false;

      int localPlaylistId;

      if (isLiked) {
        final likedPlaylist = await _playlistDao.getLikedPlaylist();
        localPlaylistId = likedPlaylist.id;
      } else {
        Playlist? match;
        for (final p in localPlaylists) {
          if (p.title == title) {
            match = p;
            break;
          }
        }

        if (match != null) {
          localPlaylistId = match.id;
        } else {
          localPlaylistId = await _playlistDao.createPlaylist(
            title: title,
            description: description,
            coverUrl: coverUrl,
          );
        }
      }

      final remoteTracks = await _playlistRepo.fetchPlaylistTracks(remoteId);
      final localTracks = await _playlistDao.getTracksOrdered(localPlaylistId);
      final localTrackIds = localTracks.map((t) => t.trackId).toSet();

      for (final trackMap in remoteTracks) {
        final trackId = (trackMap['track_id'] as num).toInt();

        if (!localTrackIds.contains(trackId)) {
          await _playlistDao.addTrackToPlaylist(
            playlistId: localPlaylistId,
            trackId: trackId,
            artistId: (trackMap['artist_id'] as num?)?.toInt() ?? 0,
            albumId: (trackMap['album_id'] as num?)?.toInt() ?? 0,
            title: trackMap['title'] as String? ?? '',
            artistName: trackMap['artist_name'] as String? ?? '',
            albumName: trackMap['album_name'] as String? ?? '',
            coverUrl: trackMap['cover_url'] as String? ?? '',
            durationMs: (trackMap['duration_ms'] as num?)?.toInt() ?? 0,
            genre: trackMap['genre'] as String?,
          );
        }
      }
    }
  }

  Future<void> _syncSavedAlbums() async {
    final remoteAlbums = await _albumRepo.fetchSavedAlbums();
    for (final albumMap in remoteAlbums) {
      final albumId = (albumMap['album_id'] as num).toInt();
      final title = albumMap['title'] as String? ?? '';
      final artistName = albumMap['artist_name'] as String? ?? '';
      final coverUrl = albumMap['cover_url'] as String? ?? '';

      await _savedAlbumDao.saveAlbum(
        albumId: albumId,
        title: title,
        artistName: artistName,
        coverUrl: coverUrl,
      );
    }
  }

  Future<void> _syncListeningHistory() async {
    final localHistory = await _listeningHistoryDao.getRecentHistory(limit: 100);
    for (final historyEntry in localHistory) {
      await _historyRepo.insertListeningHistory(
        trackId: historyEntry.trackId,
        artistId: historyEntry.artistId,
        albumId: historyEntry.albumId,
        genre: historyEntry.genre,
        durationListenedMs: historyEntry.durationListenedMs,
      );
    }
  }
}

final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService(
    playlistRepo: ref.watch(supabasePlaylistRepositoryProvider),
    albumRepo: ref.watch(supabaseAlbumRepositoryProvider),
    historyRepo: ref.watch(supabaseHistoryRepositoryProvider),
    playlistDao: ref.watch(playlistDaoProvider),
    savedAlbumDao: ref.watch(savedAlbumDaoProvider),
    listeningHistoryDao: ref.watch(listeningHistoryDaoProvider),
  );
});
