import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/apis/deezer_api.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/data/supabase/supabase_album_repository.dart';
import 'package:syncora_player/data/supabase/supabase_playlist_repository.dart';
import 'package:syncora_player/features/library/import_export/playlist_import_export_service.dart';

/// Fase 7.I.10/7.I.16 -- `migrateLocalPlaylistsToAccount` sube las
/// playlists locales sin `remoteId` a una cuenta recién creada (D-25,
/// migración one-way). Doble de [SupabasePlaylistRepository] que simula el
/// "servidor" en memoria (incluido el dedup real de "Tus me gusta" vía
/// [getOrCreateLikedPlaylist]), para poder verificar el contenido subido y,
/// sobre todo, que reintentar no duplica ni playlists ni la liked.
class _FakePlaylistRepo extends SupabasePlaylistRepository {
  int _nextRemoteId = 1;
  final List<Map<String, dynamic>> createdPlaylists = [];
  final Map<String, List<Map<String, dynamic>>> uploadedTracks = {};
  Map<String, dynamic>? likedPlaylist;

  @override
  Future<List<Map<String, dynamic>>> fetchUserPlaylists() async => createdPlaylists;

  @override
  Future<Map<String, dynamic>> createPlaylist({
    required String title,
    String? description,
    bool isPublic = false,
    bool isLiked = false,
  }) async {
    final id = 'remote_${_nextRemoteId++}';
    final created = {'id': id, 'title': title, 'description': description, 'is_public': isPublic, 'is_liked': isLiked};
    createdPlaylists.add(created);
    if (isLiked) likedPlaylist = created;
    return created;
  }

  @override
  Future<Map<String, dynamic>> getOrCreateLikedPlaylist() async {
    if (likedPlaylist != null) return likedPlaylist!;
    return createPlaylist(title: 'Tus me gusta', isLiked: true);
  }

  @override
  Future<void> addTracksToPlaylist(String playlistId, List<Map<String, dynamic>> tracksData) async {
    uploadedTracks[playlistId] = tracksData;
  }
}

class _FakeAlbumRepo extends SupabaseAlbumRepository {
  final List<Map<String, dynamic>> savedAlbums = [];

  @override
  Future<void> saveAlbum(Map<String, dynamic> albumData) async {
    savedAlbums.add(albumData);
  }
}

void main() {
  group('PlaylistImportExportService.migrateLocalPlaylistsToAccount (Fase 7.I.10/7.I.16)', () {
    late SyncoraDatabase db;
    late _FakePlaylistRepo fakeRepo;
    late PlaylistImportExportService service;

    setUp(() {
      db = SyncoraDatabase(NativeDatabase.memory());
      fakeRepo = _FakePlaylistRepo();
      service = PlaylistImportExportService(DeezerApi());
    });

    tearDown(() async {
      await db.close();
    });

    test('sube todas las playlists locales sin remoteId y marca remoteId tras subir', () async {
      // Una base local nueva ya trae "Tus me gusta" auto-creada (D-3, sin
      // `remoteId`) -- se cuenta como una playlist más a migrar, no es un
      // caso especial.
      const seededLikedPlaylist = 1;
      final id1 = await db.playlistDao.createPlaylist(title: 'Mi playlist local 1');
      final id2 = await db.playlistDao.createPlaylist(title: 'Mi playlist local 2');
      await db.playlistDao.addTrackToPlaylist(
        playlistId: id1,
        trackId: 101,
        artistId: 1,
        albumId: 1,
        title: 'Track 1',
        artistName: 'Artist 1',
        albumName: 'Album 1',
        coverUrl: '',
        durationMs: 1000,
      );

      await service.migrateLocalPlaylistsToAccount(
        dao: db.playlistDao,
        supabaseRepo: fakeRepo,
      );

      expect(fakeRepo.createdPlaylists.length, 2 + seededLikedPlaylist);

      final p1 = await db.playlistDao.getPlaylistById(id1);
      final p2 = await db.playlistDao.getPlaylistById(id2);
      expect(p1!.remoteId, isNotNull);
      expect(p2!.remoteId, isNotNull);
      expect(fakeRepo.uploadedTracks[p1.remoteId], isNotNull);
      expect(fakeRepo.uploadedTracks[p1.remoteId]!.length, 1);
      // La playlist vacía no dispara una subida de tracks vacía.
      expect(fakeRepo.uploadedTracks.containsKey(p2.remoteId), isFalse);
    });

    test('reintentar tras un "fallo parcial" no duplica lo que ya se subió (7.I.16)', () async {
      final id1 = await db.playlistDao.createPlaylist(title: 'Playlist A');
      await db.playlistDao.createPlaylist(title: 'Playlist B');
      // + "Tus me gusta" auto-creada (D-3), también sin remoteId.
      const totalPlaylists = 3;

      await service.migrateLocalPlaylistsToAccount(
        dao: db.playlistDao,
        supabaseRepo: fakeRepo,
      );
      expect(fakeRepo.createdPlaylists.length, totalPlaylists, reason: 'sin interrupción real, sube todas la primera vez');

      // Reintento (segunda llamada, simulando que el usuario reintentó la
      // migración desde Configuración): nada nuevo que subir, todas ya
      // tienen remoteId.
      await service.migrateLocalPlaylistsToAccount(
        dao: db.playlistDao,
        supabaseRepo: fakeRepo,
      );
      expect(fakeRepo.createdPlaylists.length, totalPlaylists, reason: 'el reintento no debe volver a crear playlists ya migradas');

      final refreshed = await db.playlistDao.getPlaylistById(id1);
      expect(refreshed!.remoteId, isNotNull);
    });

    test('no hace nada si no hay playlists locales sin remoteId', () async {
      await db.playlistDao.createPlaylist(title: 'Ya migrada', remoteId: 'remote_existing');
      // La "Tus me gusta" auto-creada (D-3) también necesita quedar con
      // remoteId para que este caso sea realmente "nada pendiente".
      final liked = await db.playlistDao.getLikedPlaylist();
      await db.playlistDao.updatePlaylist(liked.copyWith(remoteId: const Value('remote_liked')));

      await service.migrateLocalPlaylistsToAccount(
        dao: db.playlistDao,
        supabaseRepo: fakeRepo,
      );

      expect(fakeRepo.createdPlaylists, isEmpty);
    });

    test(
      'hallazgo de la revisión independiente: iniciar sesión en una cuenta EXISTENTE con "Tus me gusta" '
      'ya remota reusa esa liked en vez de crear una segunda',
      () async {
        // Simula una cuenta que YA tenía su "Tus me gusta" en el servidor
        // antes de que este dispositivo se conectara en modo local.
        await fakeRepo.getOrCreateLikedPlaylist();
        expect(fakeRepo.createdPlaylists.length, 1);
        final existingLikedId = fakeRepo.likedPlaylist!['id'];

        await service.migrateLocalPlaylistsToAccount(
          dao: db.playlistDao,
          supabaseRepo: fakeRepo,
        );

        // La liked local se vincula a la que ya existía -- no aparece una
        // "Tus me gusta" nueva en la lista de creadas.
        expect(fakeRepo.createdPlaylists.length, 1);
        final liked = await db.playlistDao.getLikedPlaylist();
        expect(liked.remoteId, existingLikedId);
      },
    );

    test(
      'hallazgo de la revisión independiente: si una playlist ya se creó en el servidor en un intento '
      'previo (falló antes de marcar remoteId local), el reintento la reusa por título en vez de duplicarla',
      () async {
        await db.playlistDao.createPlaylist(title: 'Playlist interrumpida');

        // Simula que un intento anterior ya llegó a crearla remotamente
        // (`createPlaylist`) pero se cortó antes de que
        // `migrateLocalPlaylistsToAccount` alcanzara a marcar `remoteId`
        // local -- exactamente el corte que el fix cubre.
        final preExisting = await fakeRepo.createPlaylist(title: 'Playlist interrumpida');
        fakeRepo.createdPlaylists.clear();
        fakeRepo.createdPlaylists.add(preExisting);

        await service.migrateLocalPlaylistsToAccount(
          dao: db.playlistDao,
          supabaseRepo: fakeRepo,
        );

        // No se creó una playlist remota nueva con el mismo título -- se
        // reusó la existente (más la "Tus me gusta" auto-creada, aparte).
        final matchingTitle = fakeRepo.createdPlaylists.where((p) => p['title'] == 'Playlist interrumpida');
        expect(matchingTitle.length, 1);
      },
    );
  });

  group('PlaylistImportExportService.migrateLocalSavedAlbumsToAccount (Fase 7.I.10)', () {
    late SyncoraDatabase db;
    late _FakeAlbumRepo fakeAlbumRepo;
    late PlaylistImportExportService service;

    setUp(() {
      db = SyncoraDatabase(NativeDatabase.memory());
      fakeAlbumRepo = _FakeAlbumRepo();
      service = PlaylistImportExportService(DeezerApi());
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'sube todos los álbumes guardados localmente (hallazgo de la revisión: sin esto, el primer '
      'syncLibrary tras crear la cuenta los podaba por completo)',
      () async {
        await db.savedAlbumDao.saveAlbum(albumId: 1, title: 'Album 1', artistName: 'Artist 1', coverUrl: '');
        await db.savedAlbumDao.saveAlbum(albumId: 2, title: 'Album 2', artistName: 'Artist 2', coverUrl: '');

        await service.migrateLocalSavedAlbumsToAccount(
          savedAlbumDao: db.savedAlbumDao,
          supabaseAlbumRepo: fakeAlbumRepo,
        );

        expect(fakeAlbumRepo.savedAlbums.length, 2);
        expect(fakeAlbumRepo.savedAlbums.map((a) => a['album_id']), containsAll([1, 2]));
      },
    );

    test('no hace nada si no hay álbumes guardados localmente', () async {
      await service.migrateLocalSavedAlbumsToAccount(
        savedAlbumDao: db.savedAlbumDao,
        supabaseAlbumRepo: fakeAlbumRepo,
      );

      expect(fakeAlbumRepo.savedAlbums, isEmpty);
    });
  });
}
