import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/limits/app_limits.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';

void main() {
  group('AppLimits (ronda 5)', () {
    test('recorta nombre y descripción largos sin partir caracteres', () {
      final long = 'á' * 150;
      expect(AppLimits.clampTitle(long).length, AppLimits.playlistTitleMax);
      expect(AppLimits.clampTitle('  Mi playlist  '), 'Mi playlist');
      expect(AppLimits.clampDescription('x' * 400)!.length, AppLimits.playlistDescriptionMax);
      expect(AppLimits.clampDescription(null), isNull);
    });

    test('espacio restante y error de límite del servidor', () {
      expect(AppLimits.roomFor(0), 10000);
      expect(AppLimits.roomFor(9990), 10);
      expect(AppLimits.roomFor(12000), 0);
      expect(AppLimits.isTrackLimitError(Exception('PostgrestException(message: playlist_track_limit)')), isTrue);
      expect(AppLimits.isTrackLimitError(Exception('row not found')), isFalse);
    });

    test('la base local recorta el nombre al crear y cuenta canciones', () async {
      final db = SyncoraDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await db.playlistDao.createPlaylist(title: 'n' * 140);
      final pl = await db.playlistDao.getPlaylistById(id);
      expect(pl!.title.length, AppLimits.playlistTitleMax);
      expect(await db.playlistDao.countTracks(id), 0);
      await db.playlistDao.addTrackToPlaylist(
        playlistId: id, trackId: 1, artistId: 1, albumId: 1, title: 't', artistName: 'a',
        albumName: 'al', coverUrl: '', durationMs: 1000,
      );
      expect(await db.playlistDao.countTracks(id), 1);
    });
  });
}
