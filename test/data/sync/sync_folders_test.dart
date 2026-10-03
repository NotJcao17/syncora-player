import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/data/supabase/supabase_album_repository.dart';
import 'package:syncora_player/data/supabase/supabase_folder_repository.dart';
import 'package:syncora_player/data/supabase/supabase_history_repository.dart';
import 'package:syncora_player/data/sync/sync_cache_manager.dart';
import 'package:syncora_player/data/sync/sync_service.dart';

import 'sync_service_test.dart' show MockSupabasePlaylistRepository;

class _FolderRepo extends SupabaseFolderRepository {
  List<Map<String, dynamic>> folders = [];
  bool fail = false;

  @override
  Future<List<Map<String, dynamic>>> fetchUserFolders() async {
    if (fail) throw Exception('relation "folders" does not exist');
    return folders;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SyncoraDatabase db;
  late MockSupabasePlaylistRepository playlistRepo;
  late _FolderRepo folderRepo;

  SyncService service() => SyncService(
        playlistRepo: playlistRepo,
        albumRepo: SupabaseAlbumRepository(),
        historyRepo: SupabaseHistoryRepository(),
        playlistDao: db.playlistDao,
        savedAlbumDao: db.savedAlbumDao,
        listeningHistoryDao: db.listeningHistoryDao,
        cacheManager: SyncCacheManager(),
        folderDao: db.folderDao,
        folderRepo: folderRepo,
      );

  setUp(() {
    db = SyncoraDatabase(NativeDatabase.memory());
    playlistRepo = MockSupabasePlaylistRepository();
    folderRepo = _FolderRepo();
  });

  tearDown(() => db.close());

  test('baja la carpeta remota y deja la playlist dentro', () async {
    folderRepo.folders = [
      {'id': 'f1', 'name': 'Rock'},
    ];
    playlistRepo.userPlaylists = [
      {'id': 'p1', 'title': 'Clásicos', 'folder_id': 'f1'},
    ];

    await service().syncLibrary(force: true);

    final folder = (await db.folderDao.getFolderByRemoteId('f1'))!;
    expect(folder.name, 'Rock');
    final playlist = (await db.playlistDao.getPlaylistByRemoteId('p1'))!;
    expect(playlist.folderId, folder.id);
  });

  test('la carpeta borrada en otro dispositivo desaparece y su playlist vuelve a la raíz', () async {
    final localFolder = await db.folderDao.createFolder(name: 'Vieja', remoteId: 'f-old');
    final pid = await db.playlistDao.createPlaylist(title: 'Clásicos', remoteId: 'p1', folderId: localFolder);
    playlistRepo.userPlaylists = [
      {'id': 'p1', 'title': 'Clásicos', 'folder_id': null},
    ];

    await service().syncLibrary(force: true);

    expect(await db.folderDao.getAllFolders(), isEmpty);
    expect((await db.playlistDao.getPlaylistById(pid))!.folderId, isNull);
  });

  test('si no se pueden leer las carpetas (migración 20 sin aplicar) no se toca ninguna', () async {
    final localFolder = await db.folderDao.createFolder(name: 'Rock', remoteId: 'f1');
    final pid = await db.playlistDao.createPlaylist(title: 'Clásicos', remoteId: 'p1', folderId: localFolder);
    folderRepo.fail = true;
    playlistRepo.userPlaylists = [
      {'id': 'p1', 'title': 'Clásicos'},
    ];

    await service().syncLibrary(force: true);

    expect((await db.folderDao.getAllFolders()).length, 1);
    expect((await db.playlistDao.getPlaylistById(pid))!.folderId, localFolder);
  });
}
