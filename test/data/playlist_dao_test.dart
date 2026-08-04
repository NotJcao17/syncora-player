import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/daos/playlist_dao.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';

void main() {
  late SyncoraDatabase db;
  late PlaylistDao playlistDao;

  setUp(() {
    db = SyncoraDatabase(NativeDatabase.memory());
    playlistDao = db.playlistDao;
  });

  tearDown(() async {
    await db.close();
  });

  group('PlaylistDao Drift Database Tests', () {
    test('Insert playlist -> read -> matches', () async {
      final id = await playlistDao.createPlaylist(
        title: 'Mi Playlist',
        description: 'Descripción de prueba',
      );

      final playlist = await playlistDao.getPlaylistById(id);
      expect(playlist, isNotNull);
      expect(playlist!.title, equals('Mi Playlist'));
      expect(playlist.description, equals('Descripción de prueba'));
    });

    test('Insert 10 tracks -> getTracksOrdered returns in correct order', () async {
      final playlistId = await playlistDao.createPlaylist(title: 'Orden Test');

      for (int i = 0; i < 10; i++) {
        await playlistDao.addTrackToPlaylist(
          playlistId: playlistId,
          trackId: 100 + i,
          artistId: 1,
          albumId: 1,
          title: 'Track $i',
          artistName: 'Artista Test',
          albumName: 'Álbum Test',
          coverUrl: 'https://cover.jpg',
          durationMs: 200000,
        );
      }

      final tracks = await playlistDao.getTracksOrdered(playlistId);
      expect(tracks.length, equals(10));
      for (int i = 0; i < 10; i++) {
        expect(tracks[i].title, equals('Track $i'));
        expect(tracks[i].orderIndex, equals(i));
      }
    });

    test('Remove track -> no longer appears in list', () async {
      final playlistId = await playlistDao.createPlaylist(title: 'Remove Test');

      await playlistDao.addTrackToPlaylist(
        playlistId: playlistId,
        trackId: 555,
        artistId: 1,
        albumId: 1,
        title: 'Track to remove',
        artistName: 'Artist',
        albumName: 'Album',
        coverUrl: 'https://cover.jpg',
        durationMs: 180000,
      );

      var tracks = await playlistDao.getTracksOrdered(playlistId);
      expect(tracks.length, equals(1));

      await playlistDao.removeTrackFromPlaylist(playlistId, 555);

      tracks = await playlistDao.getTracksOrdered(playlistId);
      expect(tracks.isEmpty, isTrue);
    });

    test('Toggle like track creates and uses Liked playlist', () async {
      final likedBefore = await playlistDao.isTrackLiked(999);
      expect(likedBefore, isFalse);

      final isLikedNow = await playlistDao.toggleLikeTrack(
        trackId: 999,
        artistId: 1,
        albumId: 1,
        title: 'Liked Song',
        artistName: 'Liked Artist',
        albumName: 'Liked Album',
        coverUrl: 'https://cover.jpg',
        durationMs: 210000,
      );

      expect(isLikedNow, isTrue);
      final likedAfter = await playlistDao.isTrackLiked(999);
      expect(likedAfter, isTrue);
    });
  });
}
