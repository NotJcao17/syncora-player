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
  });
}
