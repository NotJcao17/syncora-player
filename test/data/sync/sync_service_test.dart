import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/data/supabase/supabase_album_repository.dart';
import 'package:syncora_player/data/supabase/supabase_history_repository.dart';
import 'package:syncora_player/data/supabase/supabase_playlist_repository.dart';
import 'package:syncora_player/data/sync/sync_cache_manager.dart';
import 'package:syncora_player/data/sync/sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SyncService Tests', () {
    late SyncoraDatabase db;
    late SyncCacheManager cacheManager;
    late SyncService syncService;

    setUp(() {
      db = SyncoraDatabase(NativeDatabase.memory());
      cacheManager = SyncCacheManager();
      final playlistRepo = SupabasePlaylistRepository();
      final albumRepo = SupabaseAlbumRepository();
      final historyRepo = SupabaseHistoryRepository();

      syncService = SyncService(
        playlistRepo: playlistRepo,
        albumRepo: albumRepo,
        historyRepo: historyRepo,
        playlistDao: db.playlistDao,
        savedAlbumDao: db.savedAlbumDao,
        listeningHistoryDao: db.listeningHistoryDao,
        cacheManager: cacheManager,
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('syncOnStartup does not erase local Drift data in test environment', () async {
      await db.playlistDao.createPlaylist(
        title: 'Local Playlist 1',
        description: 'Test Description',
      );

      final initialPlaylists = await db.playlistDao.getAllPlaylists();
      expect(initialPlaylists.any((p) => p.title == 'Local Playlist 1'), isTrue);

      await syncService.syncOnStartup();

      final postSyncPlaylists = await db.playlistDao.getAllPlaylists();
      expect(postSyncPlaylists.any((p) => p.title == 'Local Playlist 1'), isTrue);
      expect(postSyncPlaylists.length, equals(initialPlaylists.length));
    });

    test('SyncService handles unauthenticated state gracefully', () async {
      expect(() async => await syncService.syncOnStartup(), returnsNormally);
    });

    test('syncPlaylistDetail deletes local playlist if remote playlist no longer exists', () async {
      final mockRepo = MockSupabasePlaylistRepository();
      mockRepo.userPlaylists = []; // Empty remote

      final mockSyncService = SyncService(
        playlistRepo: mockRepo,
        albumRepo: SupabaseAlbumRepository(),
        historyRepo: SupabaseHistoryRepository(),
        playlistDao: db.playlistDao,
        savedAlbumDao: db.savedAlbumDao,
        listeningHistoryDao: db.listeningHistoryDao,
        cacheManager: cacheManager,
      );

      final localId = await db.playlistDao.createPlaylist(
        title: 'Deleted Remote Playlist',
        remoteId: 'remote_del_123',
      );

      var local = await db.playlistDao.getPlaylistById(localId);
      expect(local, isNotNull);

      await mockSyncService.syncPlaylistDetail('remote_del_123', force: true);

      local = await db.playlistDao.getPlaylistById(localId);
      expect(local, isNull);
    });

    test('syncPlaylistDetail prunes local tracks not present in remote playlist', () async {
      final mockRepo = MockSupabasePlaylistRepository();
      mockRepo.userPlaylists = [
        {'id': 'remote_1', 'title': 'Test Playlist'}
      ];
      mockRepo.playlistTracksMap['remote_1'] = [
        {'track_id': 101, 'title': 'Track 1', 'artist_name': 'Artist 1'},
      ];

      final mockSyncService = SyncService(
        playlistRepo: mockRepo,
        albumRepo: SupabaseAlbumRepository(),
        historyRepo: SupabaseHistoryRepository(),
        playlistDao: db.playlistDao,
        savedAlbumDao: db.savedAlbumDao,
        listeningHistoryDao: db.listeningHistoryDao,
        cacheManager: cacheManager,
      );

      final localId = await db.playlistDao.createPlaylist(
        title: 'Test Playlist',
        remoteId: 'remote_1',
      );

      await db.playlistDao.addTrackToPlaylist(
        playlistId: localId,
        trackId: 101,
        artistId: 1,
        albumId: 1,
        title: 'Track 1',
        artistName: 'Artist 1',
        albumName: 'Album 1',
        coverUrl: '',
        durationMs: 1000,
      );

      await db.playlistDao.addTrackToPlaylist(
        playlistId: localId,
        trackId: 999, // Remote deleted this track!
        artistId: 1,
        albumId: 1,
        title: 'Track 999',
        artistName: 'Artist 1',
        albumName: 'Album 1',
        coverUrl: '',
        durationMs: 1000,
      );

      var tracks = await db.playlistDao.getTracksOrdered(localId);
      expect(tracks.length, equals(2));

      await mockSyncService.syncPlaylistDetail('remote_1', force: true);

      tracks = await db.playlistDao.getTracksOrdered(localId);
      expect(tracks.length, equals(1));
      expect(tracks.first.trackId, equals(101));
    });

    test('syncLibrary deduplicates multiple remote liked playlists', () async {
      final mockRepo = MockSupabasePlaylistRepository();
      mockRepo.userPlaylists = [
        {'id': 'liked_1', 'title': 'Tus me gusta', 'is_liked': true},
        {'id': 'liked_2', 'title': 'Tus me gusta', 'is_liked': true},
      ];

      final mockSyncService = SyncService(
        playlistRepo: mockRepo,
        albumRepo: SupabaseAlbumRepository(),
        historyRepo: SupabaseHistoryRepository(),
        playlistDao: db.playlistDao,
        savedAlbumDao: db.savedAlbumDao,
        listeningHistoryDao: db.listeningHistoryDao,
        cacheManager: cacheManager,
      );

      await mockSyncService.syncLibrary(force: true);

      expect(mockRepo.deletedPlaylistIds, contains('liked_2'));
      final likedLocal = await db.playlistDao.getLikedPlaylist();
      expect(likedLocal.remoteId, equals('liked_1'));
    });
  });
}

class MockSupabasePlaylistRepository extends SupabasePlaylistRepository {
  List<Map<String, dynamic>> userPlaylists = [];
  Map<String, List<Map<String, dynamic>>> playlistTracksMap = {};
  List<String> deletedPlaylistIds = [];

  @override
  Future<List<Map<String, dynamic>>> fetchUserPlaylists() async {
    return userPlaylists;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchPlaylistTracks(String playlistId) async {
    return playlistTracksMap[playlistId] ?? [];
  }

  @override
  Future<void> deletePlaylist(String id) async {
    deletedPlaylistIds.add(id);
  }
}
