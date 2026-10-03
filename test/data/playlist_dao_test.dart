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

    test('contributorsJson persiste y sobrevive el round-trip de lectura', () async {
      final playlistId = await playlistDao.createPlaylist(title: 'Colaboradores Test');
      const json = '[{"id":10,"name":"Jesse & Joy"},{"id":20,"name":"Gente De Zona"}]';

      await playlistDao.addTrackToPlaylist(
        playlistId: playlistId,
        trackId: 777,
        artistId: 10,
        albumId: 1,
        title: '3 A.M.',
        artistName: 'Jesse & Joy',
        albumName: '3 A.M.',
        coverUrl: 'https://cover.jpg',
        durationMs: 183000,
        contributorsJson: json,
      );

      final tracks = await playlistDao.getTracksOrdered(playlistId);
      expect(tracks.length, equals(1));
      expect(tracks.first.contributorsJson, equals(json));
    });

    test('contributorsJson queda null cuando no se provee (filas sin colaboración)', () async {
      final playlistId = await playlistDao.createPlaylist(title: 'Sin Colaboradores Test');

      await playlistDao.addTrackToPlaylist(
        playlistId: playlistId,
        trackId: 888,
        artistId: 1,
        albumId: 1,
        title: 'Track Solo',
        artistName: 'Artista Solo',
        albumName: 'Álbum',
        coverUrl: 'https://cover.jpg',
        durationMs: 200000,
      );

      final tracks = await playlistDao.getTracksOrdered(playlistId);
      expect(tracks.first.contributorsJson, isNull);
    });
  
    test('ronda 5: watchPlaylistSummaries cuenta y elige 4 portadas de álbumes distintos', () async {
      final a = await playlistDao.createPlaylist(title: 'A');
      final b = await playlistDao.createPlaylist(title: 'B');
      await playlistDao.createPlaylist(title: 'Vacía');
      // 6 pistas en A: dos del mismo álbum al principio y una sin portada.
      final albums = [1, 1, 2, 3, 0, 4];
      for (var i = 0; i < albums.length; i++) {
        await playlistDao.addTrackToPlaylist(
          playlistId: a,
          trackId: 200 + i,
          artistId: 1,
          albumId: albums[i],
          title: 'T$i',
          artistName: 'X',
          albumName: 'Al',
          coverUrl: i == 4 ? '' : 'c$i',
          durationMs: 1000,
        );
      }
      await playlistDao.addTrackToPlaylist(
        playlistId: b, trackId: 300, artistId: 1, albumId: 9, title: 'U', artistName: 'Y',
        albumName: 'Al', coverUrl: 'cb', durationMs: 1000,
      );

      final summaries = await playlistDao.watchPlaylistSummaries().first;
      expect(summaries[a]?.trackCount, 6);
      expect(summaries[a]?.covers, ['c0', 'c2', 'c3', 'c5']);
      expect(summaries[b], const PlaylistSummary(trackCount: 1, covers: ['cb']));
    });
});
}
