import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/images/custom_image_service.dart';
import 'package:syncora_player/data/local_db/database_provider.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/features/auth/local_mode_provider.dart';
import 'package:syncora_player/features/auth/services/account_data_owner.dart';
import 'package:syncora_player/features/search/search_history_storage.dart';

import '../search/search_history_test.dart' show InMemorySearchHistoryStorage;
import 'local_mode_provider_test.dart' show FakeLocalModeStorage;

/// Bug real (2026-10-05): al entrar con otra cuenta, Inicio, "On Repeat" y la
/// cola seguían mostrando los datos de la anterior, porque cerrar sesión no
/// borraba nada local.
void main() {
  group('shouldWipeLocalData', () {
    test('sin dueño anotado no borra (instalación previa al cambio)', () {
      expect(shouldWipeLocalData(storedOwner: null, newOwner: 'user-b'), isFalse);
    });

    test('la misma cuenta no borra: conserva lo que sirve sin conexión', () {
      expect(shouldWipeLocalData(storedOwner: 'user-a', newOwner: 'user-a'), isFalse);
    });

    test('otra cuenta borra', () {
      expect(shouldWipeLocalData(storedOwner: 'user-a', newOwner: 'user-b'), isTrue);
    });

    test('pasar de una cuenta al modo sin cuenta borra, y al revés también', () {
      expect(shouldWipeLocalData(storedOwner: 'user-a', newOwner: localModeDataOwner), isTrue);
      expect(shouldWipeLocalData(storedOwner: localModeDataOwner, newOwner: 'user-a'), isTrue);
    });
  });

  group('shouldWipeAfterServerSignOut (ronda 7: cuenta eliminada en otro dispositivo)', () {
    test('solo borra si el servidor dijo explícitamente que la cuenta no existe', () {
      expect(shouldWipeAfterServerSignOut(accountExists: false, signedInAgain: false, ownerChanged: false), isTrue);
      expect(shouldWipeAfterServerSignOut(accountExists: true, signedInAgain: false, ownerChanged: false), isFalse);
      expect(shouldWipeAfterServerSignOut(accountExists: null, signedInAgain: false, ownerChanged: false), isFalse,
          reason: 'sin red o sin respuesta no se borra nada');
    });

    test('si alguien entró o cambió el dueño mientras se preguntaba, no toca nada', () {
      expect(shouldWipeAfterServerSignOut(accountExists: false, signedInAgain: true, ownerChanged: false), isFalse);
      expect(shouldWipeAfterServerSignOut(accountExists: false, signedInAgain: false, ownerChanged: true), isFalse);
    });
  });

  group('wipeAccountDataAtRest', () {
    late SyncoraDatabase db;

    setUp(() {
      db = SyncoraDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    });

    tearDown(() async => db.close());

    Future<void> addTrack(int playlistId, int trackId) => db.playlistDao.addTrackToPlaylist(
          playlistId: playlistId,
          trackId: trackId,
          artistId: 1,
          albumId: 1,
          title: 'Pista $trackId',
          artistName: 'Artista',
          albumName: 'Álbum',
          coverUrl: '',
          durationMs: 180000,
        );

    test('borra lo de la cuenta y conserva las descargas', () async {
      final liked = await db.playlistDao.getLikedPlaylist();
      await db.playlistDao.updatePlaylist(liked.copyWith(remoteId: const Value('remote-liked')));
      await addTrack(liked.id, 1);

      final synced = await db.playlistDao.createPlaylist(title: 'Chill', remoteId: 'remote-chill');
      await addTrack(synced, 2);
      await db.playlistDao.createPlaylist(
        title: 'On Repeat',
        sourceRef: 'mix:on_repeat:2026-W40',
        isGenerated: true,
      );
      await db.folderDao.createFolder(name: 'Carpeta', remoteId: 'remote-folder');
      await db.savedAlbumDao.saveAlbum(albumId: 7, title: 'Hot Fuss', artistName: 'The Killers', coverUrl: '');
      await db.listeningHistoryDao.recordEntry(trackId: 2, artistId: 1, albumId: 1, durationListenedMs: 200000);
      await db.downloadedTrackDao.insertOrUpdate(DownloadedTracksCompanion.insert(
        trackId: 2,
        artistId: 1,
        albumId: 1,
        title: 'Pista 2',
        artistName: 'Artista',
        albumName: 'Álbum',
        coverUrl: '',
        localAudioPath: '/music/2.m4a',
        durationMs: 180000,
        downloadState: const Value(2),
      ));

      final search = InMemorySearchHistoryStorage(['killers']);
      final localMode = FakeLocalModeStorage();
      await localMode.setAvatarImagePath('custom_images/avatar.jpg');
      var sessionCleared = false;

      await wipeAccountDataAtRest(
        db: db,
        images: CustomImageService(),
        localModeStorage: localMode,
        searchHistory: search,
        clearPlayerSession: () async => sessionCleared = true,
      );

      final playlists = await db.playlistDao.getAllPlaylists();
      expect(playlists, hasLength(1), reason: 'solo sobrevive "Tus me gusta"');
      expect(playlists.single.isLiked, isTrue);
      expect(playlists.single.remoteId, isNull);
      expect(await db.playlistDao.getTracksOrdered(playlists.single.id), isEmpty);

      expect(await db.folderDao.getAllFolders(), isEmpty);
      expect(await db.savedAlbumDao.getAllSavedAlbums(), isEmpty);
      expect(await db.listeningHistoryDao.getRecentHistory(limit: 10), isEmpty);
      expect(await search.getHistory(), isEmpty);
      expect(await localMode.getAvatarImagePath(), isNull);
      expect(sessionCleared, isTrue);

      expect(await db.downloadedTrackDao.getAll(), hasLength(1), reason: 'las descargas son del dispositivo');
    });
  });

  // Ronda 8 (H-R8-14): al cerrar sesión la app ya muestra la pantalla de
  // inicio mientras el borrado sigue; si el usuario volvía a entrar antes de
  // que terminara, el sync reutilizaba las playlists que el borrado aún no
  // alcanzaba (las empareja por `remoteId`) y el borrado se las llevaba con
  // las canciones recién bajadas: la biblioteca quedaba vacía.
  test('H-R8-14: volver a entrar mientras termina el borrado no deja la biblioteca vacía', () async {
    final db = SyncoraDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    final container = ProviderContainer(overrides: [
      syncoraDatabaseProvider.overrideWithValue(db),
      localModeStorageProvider.overrideWithValue(FakeLocalModeStorage()),
      searchHistoryStorageProvider.overrideWithValue(InMemorySearchHistoryStorage(const [])),
    ]);
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    Future<void> addTrack(int playlistId, int trackId) => db.playlistDao.addTrackToPlaylist(
          playlistId: playlistId,
          trackId: trackId,
          artistId: 1,
          albumId: 1,
          title: 'Pista $trackId',
          artistName: 'Artista',
          albumName: 'Álbum',
          coverUrl: '',
          durationMs: 180000,
        );

    final guard = container.read(accountDataGuardProvider);
    await guard.setOwner('user-1');
    for (var p = 0; p < 5; p++) {
      final id = await db.playlistDao.createPlaylist(title: 'P$p', remoteId: 'remote-$p');
      for (var t = 0; t < 40; t++) {
        await addTrack(id, p * 100 + t);
      }
    }

    // Cerrar sesión: el borrado arranca y no se espera.
    final wiping = guard.wipeNow(playerAlreadyReset: true);

    // Volver a entrar con la misma cuenta y sincronizar como el sync: reusar la
    // playlist local con ese `remoteId` o crearla, y agregar lo que falta.
    await guard.claimFor('user-1');
    for (var p = 0; p < 5; p++) {
      final existing = await db.playlistDao.getPlaylistByRemoteId('remote-$p');
      final id = existing?.id ?? await db.playlistDao.createPlaylist(title: 'P$p', remoteId: 'remote-$p');
      final have = (await db.playlistDao.getTracksOrdered(id)).map((t) => t.trackId).toSet();
      for (var t = 0; t < 40; t++) {
        if (!have.contains(p * 100 + t)) await addTrack(id, p * 100 + t);
      }
    }
    await wiping;

    for (var p = 0; p < 5; p++) {
      final playlist = await db.playlistDao.getPlaylistByRemoteId('remote-$p');
      expect(playlist, isNotNull, reason: 'la playlist P$p sobrevive');
      expect(await db.playlistDao.getTracksOrdered(playlist!.id), hasLength(40));
    }
  });
}
