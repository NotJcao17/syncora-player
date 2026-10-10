import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/data/supabase/supabase_album_repository.dart';
import 'package:syncora_player/data/supabase/supabase_history_repository.dart';
import 'package:syncora_player/data/supabase/supabase_playlist_repository.dart';
import 'package:syncora_player/data/sync/sync_cache_manager.dart';
import 'package:syncora_player/data/sync/sync_locks.dart';
import 'package:syncora_player/features/catalog/save_collection_service.dart';
import 'package:syncora_player/features/player/player_models.dart';
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

    test('ronda 7: si la cuenta ya no existe (gate en false), el sync no poda nada', () async {
      final mockRepo = MockSupabasePlaylistRepository();
      mockRepo.userPlaylists = []; // Lo que responde la nube para una cuenta borrada.
      var gateCalls = 0;
      final gated = SyncService(
        playlistRepo: mockRepo,
        albumRepo: SupabaseAlbumRepository(),
        historyRepo: SupabaseHistoryRepository(),
        playlistDao: db.playlistDao,
        savedAlbumDao: db.savedAlbumDao,
        listeningHistoryDao: db.listeningHistoryDao,
        cacheManager: cacheManager,
        accountGate: () async {
          gateCalls++;
          return false;
        },
      );
      final localId = await db.playlistDao.createPlaylist(title: 'Sigue aquí', remoteId: 'remote_keep_1');

      await gated.syncPlaylistDetail('remote_keep_1', force: true);
      await gated.syncLibrary(force: true);

      expect(await db.playlistDao.getPlaylistById(localId), isNotNull);
      expect(gateCalls, 2);
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

    // Bug real encontrado en pruebas en dispositivo: instalar la app de cero
    // sobre una cuenta ya poblada dejaba TODO duplicado, porque iniciar
    // sesión, arrancar la app y abrir Biblioteca disparaban `syncLibrary` a la
    // vez y el flag de "ya sincronizado" se escribía recién al final.
    test('dos syncLibrary simultáneos ejecutan una sola corrida, no dos', () async {
      final mockRepo = MockSupabasePlaylistRepository()
        ..userPlaylists = [
          {'id': 'p1', 'title': 'Importada', 'is_liked': false},
        ]
        ..fetchDelay = const Duration(milliseconds: 40);

      final mockSyncService = SyncService(
        playlistRepo: mockRepo,
        albumRepo: SupabaseAlbumRepository(),
        historyRepo: SupabaseHistoryRepository(),
        playlistDao: db.playlistDao,
        savedAlbumDao: db.savedAlbumDao,
        listeningHistoryDao: db.listeningHistoryDao,
        cacheManager: cacheManager,
      );

      await Future.wait([
        mockSyncService.syncLibrary(force: true),
        mockSyncService.syncLibrary(force: true),
      ]);

      expect(mockRepo.fetchPlaylistTracksCalls, 1);

      final imported =
          (await db.playlistDao.getAllPlaylists()).where((p) => p.title == 'Importada').toList();
      expect(imported.length, 1);
    });

    // Fase 7.0.1/7.0.5: la sincronización de historial ya no debe reinsertar
    // en cada corrida las mismas filas (bug H-2 del plan de Fase 7).
    group('_syncListeningHistoryInternal (historial de escucha)', () {
      test('solo sube entradas no sincronizadas y las marca tras subir con éxito', () async {
        final mockHistoryRepo = MockSupabaseHistoryRepository();
        final mockSyncService = SyncService(
          playlistRepo: MockSupabasePlaylistRepository(),
          albumRepo: SupabaseAlbumRepository(),
          historyRepo: mockHistoryRepo,
          playlistDao: db.playlistDao,
          savedAlbumDao: db.savedAlbumDao,
          listeningHistoryDao: db.listeningHistoryDao,
          cacheManager: cacheManager,
        );

        await db.listeningHistoryDao.recordEntry(
          trackId: 1,
          artistId: 10,
          albumId: 100,
          durationListenedMs: 40000,
        );
        await db.listeningHistoryDao.recordEntry(
          trackId: 2,
          artistId: 20,
          albumId: 200,
          durationListenedMs: 35000,
        );

        await mockSyncService.syncListeningHistory();

        expect(mockHistoryRepo.insertedTrackIds, equals([1, 2]));

        final stillUnsynced = await db.listeningHistoryDao.getUnsyncedHistory();
        expect(stillUnsynced, isEmpty);
      });

      test('no reenvía (ni duplica) entradas que ya fueron sincronizadas en una corrida anterior',
          () async {
        final mockHistoryRepo = MockSupabaseHistoryRepository();
        final mockSyncService = SyncService(
          playlistRepo: MockSupabasePlaylistRepository(),
          albumRepo: SupabaseAlbumRepository(),
          historyRepo: mockHistoryRepo,
          playlistDao: db.playlistDao,
          savedAlbumDao: db.savedAlbumDao,
          listeningHistoryDao: db.listeningHistoryDao,
          cacheManager: cacheManager,
        );

        await db.listeningHistoryDao.recordEntry(
          trackId: 1,
          artistId: 10,
          albumId: 100,
          durationListenedMs: 40000,
        );

        // Primera sincronización: sube y marca la entrada.
        await mockSyncService.syncListeningHistory();
        expect(mockHistoryRepo.insertedTrackIds, equals([1]));

        // Nueva entrada local, distinta de la ya sincronizada.
        await db.listeningHistoryDao.recordEntry(
          trackId: 2,
          artistId: 20,
          albumId: 200,
          durationListenedMs: 35000,
        );

        // Segunda sincronización: solo debe subir la entrada nueva, la
        // anterior (ya marcada) no debe reenviarse.
        await mockSyncService.syncListeningHistory();
        expect(mockHistoryRepo.insertedTrackIds, equals([1, 2]));
      });

      test('si la subida falla, la entrada NO se marca como sincronizada (se reintenta después)',
          () async {
        final mockHistoryRepo = MockSupabaseHistoryRepository()..shouldFail = true;
        final mockSyncService = SyncService(
          playlistRepo: MockSupabasePlaylistRepository(),
          albumRepo: SupabaseAlbumRepository(),
          historyRepo: mockHistoryRepo,
          playlistDao: db.playlistDao,
          savedAlbumDao: db.savedAlbumDao,
          listeningHistoryDao: db.listeningHistoryDao,
          cacheManager: cacheManager,
        );

        await db.listeningHistoryDao.recordEntry(
          trackId: 1,
          artistId: 10,
          albumId: 100,
          durationListenedMs: 40000,
        );

        await mockSyncService.syncListeningHistory();

        final stillUnsynced = await db.listeningHistoryDao.getUnsyncedHistory();
        expect(stillUnsynced.length, 1, reason: 'un fallo de subida no debe marcar la entrada como sincronizada');
      });
    });

    // Investigación de estadísticas, root cause de "el PC no ve las
    // escuchas del celular hasta tocar Actualizar ahí": la subida ahora se
    // dispara también en `pushListeningHistoryIfDue()`, con un cooldown
    // corto para no golpear la red en cada pista si el usuario escucha
    // varias seguidas -- separado de `syncListeningHistory()` (sin cooldown,
    // usado por el botón manual/arranque) para no cambiarles el
    // comportamiento a esos otros llamadores.
    group('pushListeningHistoryIfDue (disparo reactivo, investigación de estadísticas)', () {
      test('sube de inmediato la primera vez (sin sync previo)', () async {
        final mockHistoryRepo = MockSupabaseHistoryRepository();
        final mockSyncService = SyncService(
          playlistRepo: MockSupabasePlaylistRepository(),
          albumRepo: SupabaseAlbumRepository(),
          historyRepo: mockHistoryRepo,
          playlistDao: db.playlistDao,
          savedAlbumDao: db.savedAlbumDao,
          listeningHistoryDao: db.listeningHistoryDao,
          cacheManager: cacheManager,
        );

        await db.listeningHistoryDao.recordEntry(
          trackId: 1,
          artistId: 10,
          albumId: 100,
          durationListenedMs: 40000,
        );

        await mockSyncService.pushListeningHistoryIfDue();

        expect(mockHistoryRepo.insertedTrackIds, equals([1]));
      });

      test('una segunda llamada inmediata queda en cooldown y no reenvía', () async {
        final mockHistoryRepo = MockSupabaseHistoryRepository();
        final mockSyncService = SyncService(
          playlistRepo: MockSupabasePlaylistRepository(),
          albumRepo: SupabaseAlbumRepository(),
          historyRepo: mockHistoryRepo,
          playlistDao: db.playlistDao,
          savedAlbumDao: db.savedAlbumDao,
          listeningHistoryDao: db.listeningHistoryDao,
          cacheManager: cacheManager,
        );

        await db.listeningHistoryDao.recordEntry(
          trackId: 1,
          artistId: 10,
          albumId: 100,
          durationListenedMs: 40000,
        );
        await mockSyncService.pushListeningHistoryIfDue();
        expect(mockHistoryRepo.insertedTrackIds, equals([1]));

        // Otra pista termina de escucharse casi enseguida (misma sesión).
        await db.listeningHistoryDao.recordEntry(
          trackId: 2,
          artistId: 20,
          albumId: 200,
          durationListenedMs: 35000,
        );
        await mockSyncService.pushListeningHistoryIfDue();

        expect(mockHistoryRepo.insertedTrackIds, equals([1]),
            reason: 'la segunda pista queda pendiente en Drift hasta que expire el cooldown');
        final stillUnsynced = await db.listeningHistoryDao.getUnsyncedHistory();
        expect(stillUnsynced.map((e) => e.trackId), equals([2]));
      });

      test('syncListeningHistory() (botón manual/arranque) ignora el cooldown de pushListeningHistoryIfDue',
          () async {
        final mockHistoryRepo = MockSupabaseHistoryRepository();
        final mockSyncService = SyncService(
          playlistRepo: MockSupabasePlaylistRepository(),
          albumRepo: SupabaseAlbumRepository(),
          historyRepo: mockHistoryRepo,
          playlistDao: db.playlistDao,
          savedAlbumDao: db.savedAlbumDao,
          listeningHistoryDao: db.listeningHistoryDao,
          cacheManager: cacheManager,
        );

        await db.listeningHistoryDao.recordEntry(
          trackId: 1,
          artistId: 10,
          albumId: 100,
          durationListenedMs: 40000,
        );
        await mockSyncService.pushListeningHistoryIfDue();

        await db.listeningHistoryDao.recordEntry(
          trackId: 2,
          artistId: 20,
          albumId: 200,
          durationListenedMs: 35000,
        );
        // Botón "Actualizar" de Estadísticas: debe subir sin importar el
        // cooldown del disparo reactivo.
        await mockSyncService.syncListeningHistory();

        expect(mockHistoryRepo.insertedTrackIds, equals([1, 2]));
      });
    });
  });

  test('2026-10-09: un sync a mitad de guardar una copia no le poda las canciones', () async {
    final db = SyncoraDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = MockSupabasePlaylistRepository();
    final sync = SyncService(
      playlistRepo: repo,
      albumRepo: SupabaseAlbumRepository(),
      historyRepo: SupabaseHistoryRepository(),
      playlistDao: db.playlistDao,
      savedAlbumDao: db.savedAlbumDao,
      listeningHistoryDao: db.listeningHistoryDao,
      cacheManager: SyncCacheManager(),
    );

    // Estado a mitad de `saveTracksAsPlaylist`: la remota ya existe y está
    // vacía, la local tiene canciones y todavía no tiene `remoteId`.
    final localId = await db.playlistDao.createPlaylist(title: 'Copia');
    for (final id in [1, 2, 3]) {
      await db.playlistDao.addTrackToPlaylist(
        playlistId: localId, trackId: id, artistId: 0, albumId: 0,
        title: 'T$id', artistName: 'A', albumName: '', coverUrl: '', durationMs: 0,
      );
    }
    repo.userPlaylists = [
      {'id': 'remote-copy', 'title': 'Copia'},
    ];
    SyncLocks.lock('remote-copy');
    addTearDown(() => SyncLocks.unlock('remote-copy'));

    await sync.syncLibrary(force: true);

    final local = await db.playlistDao.getPlaylistById(localId);
    expect(local!.remoteId, isNull, reason: 'no se adopta mientras se guarda');
    final tracks = await db.playlistDao.getTracksOrdered(localId);
    expect(tracks.map((t) => t.trackId), [1, 2, 3]);
  });

  test('guardar una copia bloquea la remota para el sync mientras sube', () async {
    final db = SyncoraDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = MockSupabasePlaylistRepository()..createdId = 'remote-new';

    final id = await saveTracksAsPlaylist(
      title: 'Copia',
      tracks: const [SyncoraTrack(id: '7', title: 'T7', artist: 'A')],
      dao: db.playlistDao,
      supabaseRepo: repo,
    );

    expect(repo.lockedWhileUploading, [true]);
    expect(SyncLocks.isLocked('remote-new'), isFalse, reason: 'se libera al terminar');
    expect((await db.playlistDao.getPlaylistById(id))!.remoteId, 'remote-new');
  });

  group('Pistas de playlists largas (bug de importación, 2026-10-09)', () {
    late SyncoraDatabase db;
    late MockSupabasePlaylistRepository repo;
    late SyncService sync;

    Map<String, dynamic> track(int id) => {'track_id': id, 'title': 'T$id', 'artist_name': 'A'};

    setUp(() {
      db = SyncoraDatabase(NativeDatabase.memory());
      repo = MockSupabasePlaylistRepository();
      sync = SyncService(
        playlistRepo: repo,
        albumRepo: SupabaseAlbumRepository(),
        historyRepo: SupabaseHistoryRepository(),
        playlistDao: db.playlistDao,
        savedAlbumDao: db.savedAlbumDao,
        listeningHistoryDao: db.listeningHistoryDao,
        cacheManager: SyncCacheManager(),
      );
    });

    tearDown(() async => db.close());

    test('el sync de la biblioteca y el de la playlist a la vez no duplican pistas', () async {
      final localId = await db.playlistDao.createPlaylist(title: 'Larga', remoteId: 'remote-long');
      repo.userPlaylists = [
        {'id': 'remote-long', 'title': 'Larga'},
      ];
      repo.playlistTracksMap['remote-long'] = [for (var i = 1; i <= 700; i++) track(i)];
      repo.fetchDelay = const Duration(milliseconds: 5);

      await Future.wait([
        sync.syncLibrary(force: true),
        sync.syncPlaylistDetail('remote-long', force: true),
        sync.syncPlaylistDetail('remote-long', force: true),
      ]);

      final ids = (await db.playlistDao.getTracksOrdered(localId)).map((t) => t.trackId).toList();
      expect(ids.length, 700);
      expect(ids.toSet().length, 700);
    });

    test('un duplicado local que ya existía se limpia en el siguiente sync', () async {
      final localId = await db.playlistDao.createPlaylist(title: 'Sucia', remoteId: 'remote-dirty');
      for (final id in [1, 2, 2, 3, 3, 3]) {
        await db.playlistDao.addTrackToPlaylist(
          playlistId: localId, trackId: id, artistId: 0, albumId: 0,
          title: 'T$id', artistName: 'A', albumName: '', coverUrl: '', durationMs: 0,
        );
      }
      repo.userPlaylists = [
        {'id': 'remote-dirty', 'title': 'Sucia'},
      ];
      repo.playlistTracksMap['remote-dirty'] = [track(1), track(2), track(3)];

      await sync.syncPlaylistDetail('remote-dirty', force: true);

      final ids = (await db.playlistDao.getTracksOrdered(localId)).map((t) => t.trackId).toList();
      expect(ids, [1, 2, 3]);
    });

    test('fetchAllPages junta todas las páginas de 1000 (max_rows de Supabase)', () async {
      final all = [for (var i = 0; i < 2500; i++) {'track_id': i}];
      final ranges = <String>[];
      final rows = await SupabasePlaylistRepository.fetchAllPages((from, to) async {
        ranges.add('$from-$to');
        return all.sublist(from, to + 1 > all.length ? all.length : to + 1);
      });
      expect(rows.length, 2500);
      expect(ranges, ['0-999', '1000-1999', '2000-2999']);

      // Justo 2000: pide una página más y llega vacía.
      final exact = [for (var i = 0; i < 2000; i++) {'track_id': i}];
      final rows2 = await SupabasePlaylistRepository.fetchAllPages(
        (from, to) async => from >= exact.length ? [] : exact.sublist(from, to + 1),
      );
      expect(rows2.length, 2000);
    });
  });

  group('Playlists guardadas de otros usuarios', () {
    late SyncoraDatabase db;
    late MockSupabasePlaylistRepository repo;
    late SyncService sync;

    Map<String, dynamic> track(int id) => {'track_id': id, 'title': 'T$id', 'artist_name': 'A'};

    setUp(() {
      db = SyncoraDatabase(NativeDatabase.memory());
      repo = MockSupabasePlaylistRepository();
      sync = SyncService(
        playlistRepo: repo,
        albumRepo: SupabaseAlbumRepository(),
        historyRepo: SupabaseHistoryRepository(),
        playlistDao: db.playlistDao,
        savedAlbumDao: db.savedAlbumDao,
        listeningHistoryDao: db.listeningHistoryDao,
        cacheManager: SyncCacheManager(),
      );
    });

    tearDown(() async => db.close());

    Future<List<Playlist>> followedLocal() async =>
        (await db.playlistDao.getAllPlaylists()).where((p) => p.isFollowed).toList();

    test('el sync baja la guardada como solo lectura y respeta el orden de la original', () async {
      repo.followedIds = ['shared-1'];
      repo.publicPlaylists['shared-1'] = {'id': 'shared-1', 'title': 'De un amigo', 'cover_url': 'gradient:2'};
      repo.playlistTracksMap['shared-1'] = [track(30), track(10), track(20)];

      await sync.syncLibrary(force: true);

      final followed = await followedLocal();
      expect(followed, hasLength(1));
      expect(followed.single.remoteId, 'shared-1');
      expect(followed.single.title, 'De un amigo');
      expect(followed.single.coverUrl, 'gradient:2');
      final tracks = await db.playlistDao.getTracksOrdered(followed.single.id);
      expect(tracks.map((t) => t.trackId), [30, 10, 20]);
    });

    test('el sync de las propias no poda la guardada ni la adopta por título', () async {
      repo.followedIds = ['shared-1'];
      repo.publicPlaylists['shared-1'] = {'id': 'shared-1', 'title': 'Mismo nombre'};
      await sync.syncLibrary(force: true);

      // Ahora el usuario tiene una propia con el mismo nombre en la nube.
      repo.userPlaylists = [
        {'id': 'own-1', 'title': 'Mismo nombre'},
      ];
      await sync.syncLibrary(force: true);

      final all = await db.playlistDao.getAllPlaylists();
      final followed = all.where((p) => p.isFollowed).toList();
      final own = all.where((p) => p.remoteId == 'own-1').toList();
      expect(followed.single.remoteId, 'shared-1');
      expect(own.single.isFollowed, isFalse);
    });

    test('se quita cuando el dueño la deja de compartir o ya no está guardada', () async {
      repo.followedIds = ['shared-1', 'shared-2'];
      repo.publicPlaylists['shared-1'] = {'id': 'shared-1', 'title': 'Uno'};
      repo.publicPlaylists['shared-2'] = {'id': 'shared-2', 'title': 'Dos'};
      await sync.syncLibrary(force: true);
      expect(await followedLocal(), hasLength(2));

      repo.publicPlaylists.remove('shared-1'); // privada o borrada
      repo.followedIds = ['shared-1', 'shared-2'];
      await sync.syncLibrary(force: true);

      expect((await followedLocal()).map((p) => p.remoteId), ['shared-2']);
    });

    test('sin red para leer las guardadas no se poda nada', () async {
      repo.followedIds = ['shared-1'];
      repo.publicPlaylists['shared-1'] = {'id': 'shared-1', 'title': 'Uno'};
      await sync.syncLibrary(force: true);

      repo.failFollowedFetch = true;
      await sync.syncLibrary(force: true);

      expect(await followedLocal(), hasLength(1));
    });

    test('abrir una guardada no la borra por no estar entre las propias', () async {
      repo.followedIds = ['shared-1'];
      repo.publicPlaylists['shared-1'] = {'id': 'shared-1', 'title': 'Uno'};
      repo.playlistTracksMap['shared-1'] = [track(1)];
      await sync.syncLibrary(force: true);

      repo.playlistTracksMap['shared-1'] = [track(2), track(1)];
      await sync.syncPlaylistDetail('shared-1', force: true);

      final followed = await followedLocal();
      expect(followed, hasLength(1));
      final tracks = await db.playlistDao.getTracksOrdered(followed.single.id);
      expect(tracks.map((t) => t.trackId), [2, 1]);

      // Y si el dueño la hizo privada, al abrirla desaparece.
      repo.publicPlaylists.clear();
      await sync.syncPlaylistDetail('shared-1', force: true);
      expect(await followedLocal(), isEmpty);
    });

    test('guardar dos veces a la vez no duplica la playlist', () async {
      repo.publicPlaylists['shared-1'] = {'id': 'shared-1', 'title': 'Uno'};
      repo.fetchDelay = const Duration(milliseconds: 20);
      final ids = await Future.wait([
        sync.pullFollowedPlaylist('shared-1'),
        sync.pullFollowedPlaylist('shared-1'),
      ]);
      expect(ids[0], ids[1]);
      expect(await followedLocal(), hasLength(1));
    });
  });
}

class MockSupabasePlaylistRepository extends SupabasePlaylistRepository {
  List<Map<String, dynamic>> userPlaylists = [];
  Map<String, List<Map<String, dynamic>>> playlistTracksMap = {};
  List<String> deletedPlaylistIds = [];

  /// Cuántas veces se pidieron las pistas de una playlist. Una corrida de
  /// `syncLibrary` lo hace una vez por playlist, así que sirve para detectar
  /// corridas simultáneas.
  ///
  /// No se cuenta `fetchUserPlaylists` porque una sola corrida ya la llama dos
  /// veces (hay una recomprobación al final para recuperar el `remoteId` de
  /// "Tus me gusta"), así que ese contador no distingue una corrida de dos.
  int fetchPlaylistTracksCalls = 0;

  /// Retraso artificial, para poder solapar dos llamadas en un test.
  Duration fetchDelay = Duration.zero;

  @override
  Future<List<Map<String, dynamic>>> fetchUserPlaylists() async {
    if (fetchDelay > Duration.zero) await Future<void>.delayed(fetchDelay);
    return userPlaylists;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchPlaylistTracks(String playlistId) async {
    fetchPlaylistTracksCalls++;
    if (fetchDelay > Duration.zero) await Future<void>.delayed(fetchDelay);
    return playlistTracksMap[playlistId] ?? [];
  }

  @override
  Future<void> deletePlaylist(String id) async {
    deletedPlaylistIds.add(id);
  }

  // Playlists compartidas que el usuario guardó (`followed_playlists`).
  List<String> followedIds = [];
  /// Playlists públicas de otros usuarios, por id.
  Map<String, Map<String, dynamic>> publicPlaylists = {};
  bool failFollowedFetch = false;

  @override
  Future<List<String>> fetchFollowedPlaylistIds() async {
    if (failFollowedFetch) throw Exception('sin red');
    return followedIds;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchPublicPlaylists(List<String> ids) async =>
      [for (final id in ids) ?publicPlaylists[id]];

  /// Id que devuelve `createPlaylist`; `null` = sin nube (como el real en tests).
  String? createdId;
  /// ¿Estaba bloqueada para el sync la playlist cuando se subieron sus pistas?
  final List<bool> lockedWhileUploading = [];

  @override
  Future<Map<String, dynamic>> createPlaylist({
    required String title,
    String? description,
    String? coverUrl,
    bool isPublic = false,
    bool isLiked = false,
    bool isPinned = false,
  }) async =>
      createdId == null ? {} : {'id': createdId};

  @override
  Future<void> addTracksToPlaylist(String playlistId, List<Map<String, dynamic>> tracksData) async {
    lockedWhileUploading.add(SyncLocks.isLocked(playlistId));
  }

  @override
  Future<Map<String, dynamic>?> fetchPublicPlaylist(String playlistId) async {
    if (fetchDelay > Duration.zero) await Future<void>.delayed(fetchDelay);
    return publicPlaylists[playlistId];
  }
}

class MockSupabaseHistoryRepository extends SupabaseHistoryRepository {
  final List<int> insertedTrackIds = [];
  bool shouldFail = false;

  /// Tamano de cada lote recibido, para comprobar que el push agrupa en vez
  /// de mandar una peticion por escucha (H-S4).
  final List<int> batchSizes = [];

  @override
  Future<bool> insertListeningHistoryBatch(List<Map<String, dynamic>> entries) async {
    if (shouldFail) {
      throw Exception('Simulated network failure');
    }
    batchSizes.add(entries.length);
    insertedTrackIds.addAll(entries.map((e) => e['track_id'] as int));
    return true;
  }

  @override
  Future<void> insertListeningHistory({
    required int trackId,
    required DateTime listenedAt,
    int? artistId,
    int? albumId,
    String? genre,
    int? durationListenedMs,
  }) async {
    if (shouldFail) {
      throw Exception('Simulated network failure');
    }
    insertedTrackIds.add(trackId);
  }
}
