import 'dart:io';
import 'package:drift/drift.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/auth/auth_provider.dart';
import '../local_db/daos/playlist_dao.dart';
import '../local_db/daos/saved_album_dao.dart';
import '../supabase/supabase_album_repository.dart';
import '../supabase/supabase_playlist_repository.dart';

class RealtimeSyncService {
  final SupabasePlaylistRepository _playlistRepo;
  final SupabaseAlbumRepository _albumRepo;
  final PlaylistDao _playlistDao;
  final SavedAlbumDao _savedAlbumDao;
  final Ref? _ref;

  RealtimeChannel? _channel;
  AppLifecycleListener? _lifecycleListener;
  String? _subscribedUserId;

  RealtimeSyncService({
    required SupabasePlaylistRepository playlistRepo,
    required SupabaseAlbumRepository albumRepo,
    required PlaylistDao playlistDao,
    required SavedAlbumDao savedAlbumDao,
    Ref? ref,
  })  : _playlistRepo = playlistRepo, // ignore: prefer_initializing_formals
        _albumRepo = albumRepo, // ignore: prefer_initializing_formals
        _playlistDao = playlistDao, // ignore: prefer_initializing_formals
        _savedAlbumDao = savedAlbumDao, // ignore: prefer_initializing_formals
        _ref = ref; // ignore: prefer_initializing_formals

  bool get _isTestEnv => Platform.environment.containsKey('FLUTTER_TEST');

  void subscribe(String userId) {
    if (_isTestEnv) return;

    try {
      if (_channel != null) {
        unsubscribe();
      }

      _subscribedUserId = userId;
      final client = Supabase.instance.client;
      _channel = client.channel('public-db-changes');

      _channel!
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'playlists',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: userId,
            ),
            callback: (payload) => _handlePlaylistChange(payload),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'playlist_tracks',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: userId,
            ),
            callback: (payload) => _handlePlaylistTrackChange(payload),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'saved_albums',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'user_id',
              value: userId,
            ),
            callback: (payload) => _handleSavedAlbumChange(payload),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'profiles',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'id',
              value: userId,
            ),
            callback: (payload) => _handleProfileChange(payload),
          )
          .subscribe();

      // Listener para pausar WebSockets en background (ahorro de datos y batería)
      _lifecycleListener ??= AppLifecycleListener(
        onPause: () {
          if (_channel != null) {
            try {
              Supabase.instance.client.removeChannel(_channel!);
            } catch (_) {}
            _channel = null;
          }
        },
        onResume: () {
          if (_subscribedUserId != null && _channel == null) {
            subscribe(_subscribedUserId!);
          }
        },
      );
    } catch (_) {}
  }

  void unsubscribe() {
    if (_isTestEnv) return;
    try {
      _subscribedUserId = null;
      if (_channel != null) {
        Supabase.instance.client.removeChannel(_channel!);
        _channel = null;
      }
      _lifecycleListener?.dispose();
      _lifecycleListener = null;
    } catch (_) {}
  }

  Future<void> _handlePlaylistChange(PostgresChangePayload payload) async {
    try {
      final eventType = payload.eventType;
      if (eventType == PostgresChangeEvent.delete) {
        final remoteId = payload.oldRecord['id']?.toString();
        if (remoteId != null) {
          final local = await _playlistDao.getPlaylistByRemoteId(remoteId);
          if (local != null) {
            await _playlistDao.deletePlaylist(local.id);
          }
        }
      } else {
        final record = payload.newRecord;
        if (record.isEmpty) return;

        final String remoteId = record['id'].toString();
        final String title = record['title'] as String? ?? 'Untitled';
        final String? description = record['description'] as String?;
        final String? coverUrl = record['cover_url'] as String?;
        final bool isLiked = record['is_liked'] as bool? ?? false;
        final bool isPublic = record['is_public'] as bool? ?? false;

        int localPlaylistId;
        if (isLiked) {
          final likedPlaylist = await _playlistDao.getLikedPlaylist();
          localPlaylistId = likedPlaylist.id;
          if (likedPlaylist.remoteId != remoteId) {
            await _playlistDao.updatePlaylist(
              likedPlaylist.copyWith(remoteId: Value(remoteId)),
            );
          }
        } else {
          var match = await _playlistDao.getPlaylistByRemoteId(remoteId);
          final localPlaylists = await _playlistDao.getAllPlaylists();
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
    } catch (_) {}
  }

  Future<void> _handlePlaylistTrackChange(PostgresChangePayload payload) async {
    try {
      final eventType = payload.eventType;
      if (eventType == PostgresChangeEvent.delete) {
        final playlistRemoteId = payload.oldRecord['playlist_id']?.toString();
        final trackId = (payload.oldRecord['track_id'] as num?)?.toInt();
        if (playlistRemoteId != null && trackId != null) {
          final localPlaylist =
              await _playlistDao.getPlaylistByRemoteId(playlistRemoteId);
          if (localPlaylist != null) {
            await _playlistDao.removeTrackFromPlaylist(
              localPlaylist.id,
              trackId,
            );
          }
        }
      } else {
        final record = payload.newRecord;
        if (record.isEmpty) return;

        final playlistRemoteId = record['playlist_id']?.toString();
        if (playlistRemoteId == null) return;

        final localPlaylist =
            await _playlistDao.getPlaylistByRemoteId(playlistRemoteId);
        if (localPlaylist != null) {
          final trackId = (record['track_id'] as num).toInt();
          final localTracks =
              await _playlistDao.getTracksOrdered(localPlaylist.id);
          final exists = localTracks.any((t) => t.trackId == trackId);
          if (!exists) {
            await _playlistDao.addTrackToPlaylist(
              playlistId: localPlaylist.id,
              trackId: trackId,
              artistId: (record['artist_id'] as num?)?.toInt() ?? 0,
              albumId: (record['album_id'] as num?)?.toInt() ?? 0,
              title: record['title'] as String? ?? '',
              artistName: record['artist_name'] as String? ?? '',
              albumName: record['album_name'] as String? ?? '',
              coverUrl: record['cover_url'] as String? ?? '',
              durationMs: (record['duration_ms'] as num?)?.toInt() ?? 0,
              genre: record['genre'] as String?,
            );
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _handleSavedAlbumChange(PostgresChangePayload payload) async {
    try {
      final eventType = payload.eventType;
      if (eventType == PostgresChangeEvent.delete) {
        final albumId = (payload.oldRecord['album_id'] as num?)?.toInt();
        if (albumId != null) {
          await _savedAlbumDao.removeSavedAlbum(albumId);
        }
      } else {
        final record = payload.newRecord;
        if (record.isNotEmpty) {
          final albumId = (record['album_id'] as num).toInt();
          final title = record['title'] as String? ?? '';
          final artistName = record['artist_name'] as String? ?? '';
          final coverUrl = record['cover_url'] as String? ?? '';

          await _savedAlbumDao.saveAlbum(
            albumId: albumId,
            title: title,
            artistName: artistName,
            coverUrl: coverUrl,
          );
        } else {
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
      }
    } catch (_) {}
  }

  void _handleProfileChange(PostgresChangePayload payload) {
    try {
      if (_ref != null) {
        _ref.invalidate(profileProvider);
      }
    } catch (_) {}
  }
}
