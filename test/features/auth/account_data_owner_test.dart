import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/images/custom_image_service.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/features/auth/services/account_data_owner.dart';

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
}
