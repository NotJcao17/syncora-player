import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/data/supabase/supabase_folder_repository.dart';
import 'package:syncora_player/data/supabase/supabase_playlist_repository.dart';
import 'package:syncora_player/features/library/library_folders.dart';
import 'package:syncora_player/features/library/services/folder_service.dart';

class _FakeFolderRepo extends SupabaseFolderRepository {
  bool fail = false;
  int _seq = 0;
  final Map<String, String> remote = {}; // id -> name

  @override
  Future<List<Map<String, dynamic>>> fetchUserFolders() async =>
      [for (final e in remote.entries) {'id': e.key, 'name': e.value}];

  @override
  Future<String> createFolder(String name) async {
    if (fail) throw Exception('sin red');
    final id = 'f${++_seq}';
    remote[id] = name;
    return id;
  }

  @override
  Future<void> renameFolder(String id, String name) async {
    if (fail) throw Exception('sin red');
    remote[id] = name;
  }

  @override
  Future<void> deleteFolder(String id) async {
    if (fail) throw Exception('sin red');
    remote.remove(id);
  }
}

class _FakePlaylistRepo extends SupabasePlaylistRepository {
  bool fail = false;
  final Map<String, String?> folderOf = {}; // playlist remote id -> folder remote id

  @override
  Future<void> updatePlaylist(
    String id, {
    String? title,
    String? description,
    String? coverUrl,
    bool clearCoverUrl = false,
    bool clearDescription = false,
    bool? isPublic,
    bool? isPinned,
    int? orderIndex,
    String? folderId,
    bool clearFolder = false,
  }) async {
    if (fail) throw Exception('sin red');
    if (clearFolder) {
      folderOf[id] = null;
    } else if (folderId != null) {
      folderOf[id] = folderId;
    }
  }
}

Playlist _pl(int id, {bool pinned = false, int? folderId, bool liked = false}) => Playlist(
      id: id,
      title: 'P$id',
      isPublic: false,
      isLiked: liked,
      isPinned: pinned,
      orderIndex: 0,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      isGenerated: false,
      isFollowed: false,
      folderId: folderId,
    );

Folder _f(int id) => Folder(id: id, name: 'F$id', orderIndex: 0, createdAt: DateTime(2026));

void main() {
  group('buildLibraryEntries', () {
    test('fijadas, luego carpetas, luego el resto; lo de una carpeta solo dentro de ella', () {
      final entries = buildLibraryEntries(
        [_pl(1, pinned: true), _pl(2), _pl(3, folderId: 10), _pl(4)],
        [_f(10), _f(11)],
      );
      expect(entries.map((e) => switch (e) {
            PlaylistEntry(:final playlist) => 'p${playlist.id}',
            FolderEntry(:final folder) => 'f${folder.id}',
          }), ['p1', 'f10', 'f11', 'p2', 'p4']);
      final f10 = entries.whereType<FolderEntry>().first;
      expect(f10.playlists.map((p) => p.id), [3]);
    });

    test('una playlist cuya carpeta ya no existe vuelve a la raíz', () {
      final entries = buildLibraryEntries([_pl(1, folderId: 99)], const []);
      expect(entries.single, isA<PlaylistEntry>());
    });
  });

  group('FolderService', () {
    late SyncoraDatabase db;
    late _FakeFolderRepo folderRepo;
    late _FakePlaylistRepo playlistRepo;
    var localMode = true;

    FolderService service() => FolderService(
          folderDao: db.folderDao,
          playlistDao: db.playlistDao,
          folderRepo: folderRepo,
          playlistRepo: playlistRepo,
          isLocalMode: () => localMode,
        );

    setUp(() {
      db = SyncoraDatabase(NativeDatabase.memory());
      folderRepo = _FakeFolderRepo();
      playlistRepo = _FakePlaylistRepo();
      localMode = true;
    });

    tearDown(() => db.close());

    test('modo local: crea, mueve y al borrar la carpeta la playlist vuelve a la raíz', () async {
      final s = service();
      final folderId = (await s.createFolder('  Rock  '))!;
      final folder = (await db.folderDao.getFolderById(folderId))!;
      expect(folder.name, 'Rock');
      expect(folder.remoteId, isNull);

      final playlistId = await db.playlistDao.createPlaylist(title: 'Mía');
      final playlist = (await db.playlistDao.getPlaylistById(playlistId))!;
      expect(await s.movePlaylist(playlist, folder), isTrue);
      expect((await db.playlistDao.getPlaylistById(playlistId))!.folderId, folderId);

      expect(await s.deleteFolder(folder), isTrue);
      final after = (await db.playlistDao.getPlaylistById(playlistId))!;
      expect(after.folderId, isNull, reason: 'borrar una carpeta nunca borra sus playlists');
      expect(await db.folderDao.getAllFolders(), isEmpty);
    });

    test('nombres vacíos no crean nada', () async {
      expect(await service().createFolder('   '), isNull);
      expect(await db.folderDao.getAllFolders(), isEmpty);
    });

    test('"Tus me gusta" no entra en carpetas', () async {
      final s = service();
      final folder = (await db.folderDao.getFolderById((await s.createFolder('X'))!))!;
      final liked = await db.playlistDao.getLikedPlaylist();
      expect(await s.movePlaylist(liked, folder), isFalse);
    });

    test('con cuenta: si la nube falla no se toca nada local (Pitfall #28)', () async {
      localMode = false;
      final s = service();
      folderRepo.fail = true;
      expect(await s.createFolder('Rock'), isNull);
      expect(await db.folderDao.getAllFolders(), isEmpty);

      folderRepo.fail = false;
      final folder = (await db.folderDao.getFolderById((await s.createFolder('Rock'))!))!;
      expect(folder.remoteId, 'f1');

      final playlistId = await db.playlistDao.createPlaylist(title: 'Mía', remoteId: 'p1');
      final playlist = (await db.playlistDao.getPlaylistById(playlistId))!;
      playlistRepo.fail = true;
      expect(await s.movePlaylist(playlist, folder), isFalse);
      expect((await db.playlistDao.getPlaylistById(playlistId))!.folderId, isNull);

      playlistRepo.fail = false;
      expect(await s.movePlaylist(playlist, folder), isTrue);
      expect(playlistRepo.folderOf['p1'], 'f1');
      expect(await s.movePlaylist(playlist, null), isTrue);
      expect(playlistRepo.folderOf['p1'], isNull, reason: 'sacar de la carpeta manda NULL explícito');
    });

    test('migración local → cuenta: sube carpetas sin duplicar y luego sus asignaciones', () async {
      final s = service();
      final folderId = (await s.createFolder('Rock'))!;
      final playlistId = await db.playlistDao.createPlaylist(title: 'Mía');
      await db.folderDao.setPlaylistFolder(playlistId, folderId);
      // La playlist ya se subió (migrateLocalPlaylistsToAccount corre antes).
      final p = (await db.playlistDao.getPlaylistById(playlistId))!;
      await db.playlistDao.updatePlaylist(p.copyWith(remoteId: const Value('p1')));
      // Una carpeta remota con el mismo nombre de un intento anterior.
      folderRepo.remote['f-old'] = 'Rock';

      localMode = false;
      await s.migrateLocalFoldersToAccount();

      expect((await db.folderDao.getFolderById(folderId))!.remoteId, 'f-old');
      expect(folderRepo.remote.length, 1, reason: 'no la duplica');
      expect(playlistRepo.folderOf['p1'], 'f-old');
    });
  });
}
