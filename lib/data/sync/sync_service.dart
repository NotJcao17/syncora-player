import 'dart:io';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../local_db/daos/listening_history_dao.dart';
import '../local_db/daos/playlist_dao.dart';
import '../local_db/daos/saved_album_dao.dart';
import '../local_db/database_provider.dart';
import '../local_db/syncora_database.dart';
import '../supabase/supabase_album_repository.dart';
import '../supabase/supabase_history_repository.dart';
import '../supabase/supabase_playlist_repository.dart';
import '../supabase/supabase_providers.dart';
import 'sync_cache_manager.dart';

class SyncService {
  final SupabasePlaylistRepository _playlistRepo;
  final SupabaseAlbumRepository _albumRepo;
  final SupabaseHistoryRepository _historyRepo;
  final PlaylistDao _playlistDao;
  final SavedAlbumDao _savedAlbumDao;
  final ListeningHistoryDao _listeningHistoryDao;
  final SyncCacheManager _cacheManager;

  SyncService({
    required SupabasePlaylistRepository playlistRepo,
    required SupabaseAlbumRepository albumRepo,
    required SupabaseHistoryRepository historyRepo,
    required PlaylistDao playlistDao,
    required SavedAlbumDao savedAlbumDao,
    required ListeningHistoryDao listeningHistoryDao,
    required SyncCacheManager cacheManager,
  })  : _playlistRepo = playlistRepo,
        _albumRepo = albumRepo,
        _historyRepo = historyRepo,
        _playlistDao = playlistDao,
        _savedAlbumDao = savedAlbumDao,
        _listeningHistoryDao = listeningHistoryDao,
        _cacheManager = cacheManager;

  bool get _isTestEnv => Platform.environment.containsKey('FLUTTER_TEST');

  Future<void> syncOnStartup() async {
    if (_isTestEnv) return;

    try {
      final currentUser = Supabase.instance.client.auth.currentUser;
      if (currentUser == null) {
        return;
      }
    } catch (_) {
      return;
    }

    await syncLibrary(force: false);
    await syncSavedAlbums(force: false);
    await syncListeningHistory();
  }

  Future<void> syncLibrary({bool force = false}) async {
    if (!force && !_cacheManager.isExpired('library')) {
      return;
    }

    try {
      await _syncPlaylistsAndTracks();
      _cacheManager.markSynced('library');
    } catch (_) {
      // Network/offline error caught silently, fallback to local DB
    }
  }

  Future<void> syncPlaylistDetail(String playlistRemoteId, {bool force = false}) async {
    final cacheKey = 'playlist_$playlistRemoteId';
    if (!force && !_cacheManager.isExpired(cacheKey)) {
      return;
    }

    try {
      final remoteTracks = await _playlistRepo.fetchPlaylistTracks(playlistRemoteId);
      final localPlaylist = await _playlistDao.getPlaylistByRemoteId(playlistRemoteId);

      if (localPlaylist != null) {
        final localTracks = await _playlistDao.getTracksOrdered(localPlaylist.id);
        final localTrackIds = localTracks.map((t) => t.trackId).toSet();

        for (final trackMap in remoteTracks) {
          final trackId = (trackMap['track_id'] as num).toInt();

          if (!localTrackIds.contains(trackId)) {
            await _playlistDao.addTrackToPlaylist(
              playlistId: localPlaylist.id,
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
      _cacheManager.markSynced(cacheKey);
    } catch (_) {
      // Network/offline error caught silently, fallback to local DB
    }
  }

  Future<void> syncSavedAlbums({bool force = false}) async {
    if (!force && !_cacheManager.isExpired('saved_albums')) {
      return;
    }

    try {
      await _syncSavedAlbumsInternal();
      _cacheManager.markSynced('saved_albums');
    } catch (_) {
      // Network/offline error caught silently, fallback to local DB
    }
  }

  Future<void> syncListeningHistory() async {
    try {
      await _syncListeningHistoryInternal();
    } catch (_) {
      // Network/offline error caught silently
    }
  }

  Future<void> _syncPlaylistsAndTracks() async {
    final remotePlaylists = await _playlistRepo.fetchUserPlaylists();
    final localPlaylists = await _playlistDao.getAllPlaylists();
    final remoteIdsSet = <String>{};

    for (final remote in remotePlaylists) {
      final String remoteId = remote['id'].toString();
      remoteIdsSet.add(remoteId);

      final String title = remote['title'] as String? ?? 'Untitled';
      final String? description = remote['description'] as String?;
      final String? coverUrl = remote['cover_url'] as String?;
      final bool isLiked = remote['is_liked'] as bool? ?? false;
      final bool isPublic = remote['is_public'] as bool? ?? false;

      int localPlaylistId;

      if (isLiked) {
        final likedPlaylist = await _playlistDao.getLikedPlaylist();
        localPlaylistId = likedPlaylist.id;
        if (likedPlaylist.remoteId != remoteId) {
          await _playlistDao.updatePlaylist(
              likedPlaylist.copyWith(remoteId: Value(remoteId)));
        }
      } else {
        Playlist? match = await _playlistDao.getPlaylistByRemoteId(remoteId);
        match ??= localPlaylists
            .where((p) => p.title == title && !p.isLiked)
            .firstOrNull;

        if (match != null) {
          localPlaylistId = match.id;
          await _playlistDao.updatePlaylist(
            match.copyWith(
              remoteId: Value(remoteId),
              title: title,
              description: Value(description),
              coverUrl: Value(coverUrl),
              isPublic: isPublic,
            ),
          );
        } else {
          localPlaylistId = await _playlistDao.createPlaylist(
            title: title,
            description: description,
            coverUrl: coverUrl,
            remoteId: remoteId,
            isPublic: isPublic,
          );
        }
      }

      final remoteTracks = await _playlistRepo.fetchPlaylistTracks(remoteId);
      final localTracks =
          await _playlistDao.getTracksOrdered(localPlaylistId);
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

    for (final localP in localPlaylists) {
      if (!localP.isLiked &&
          localP.remoteId != null &&
          !remoteIdsSet.contains(localP.remoteId)) {
        await _playlistDao.deletePlaylist(localP.id);
      }
    }
  }

  Future<void> _syncSavedAlbumsInternal() async {
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

  Future<void> _syncListeningHistoryInternal() async {
    final localHistory =
        await _listeningHistoryDao.getRecentHistory(limit: 100);
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
    cacheManager: ref.watch(syncCacheManagerProvider),
  );
});
