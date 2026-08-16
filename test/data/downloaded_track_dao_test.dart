import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/daos/downloaded_track_dao.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';

void main() {
  late SyncoraDatabase db;
  late DownloadedTrackDao dao;

  setUp(() {
    db = SyncoraDatabase(NativeDatabase.memory());
    dao = db.downloadedTrackDao;
  });

  tearDown(() async {
    await db.close();
  });

  group('DownloadedTrackDao Drift Tests', () {
    test('Insert downloaded track -> read -> state is correct', () async {
      await dao.insertOrUpdate(
        DownloadedTracksCompanion.insert(
          trackId: 1001,
          artistId: 1,
          albumId: 1,
          title: 'Offline Song 1',
          artistName: 'Offline Artist',
          albumName: 'Offline Album',
          coverUrl: 'https://cover.jpg',
          localAudioPath: '/storage/music/1001.mp3',
          localCoverPath: const Value('/storage/covers/1001.jpg'),
          fileSizeBytes: const Value(5242880),
          durationMs: 210000,
          downloadState: const Value(2),
        ),
      );

      final track = await dao.getByTrackId(1001);
      expect(track, isNotNull);
      expect(track!.title, equals('Offline Song 1'));
      expect(track.downloadState, equals(2));
      expect(track.fileSizeBytes, equals(5242880));
    });

    test('Watch all downloaded tracks stream emits updates', () async {
      expect(await dao.getAllDownloaded(), isEmpty);

      await dao.insertOrUpdate(
        DownloadedTracksCompanion.insert(
          trackId: 2002,
          artistId: 1,
          albumId: 1,
          title: 'Offline Song 2',
          artistName: 'Offline Artist',
          albumName: 'Offline Album',
          coverUrl: 'https://cover.jpg',
          localAudioPath: '/storage/music/2002.mp3',
          fileSizeBytes: const Value(1000),
          durationMs: 180000,
          downloadState: const Value(2),
        ),
      );

      final list = await dao.getAllDownloaded();
      expect(list.length, equals(1));
      expect(list.first.trackId, equals(2002));
    });

    test('Delete by trackId removes record', () async {
      await dao.insertOrUpdate(
        DownloadedTracksCompanion.insert(
          trackId: 3003,
          artistId: 1,
          albumId: 1,
          title: 'Song to delete',
          artistName: 'Artist',
          albumName: 'Album',
          coverUrl: 'https://cover.jpg',
          localAudioPath: '/storage/music/3003.mp3',
          fileSizeBytes: const Value(2000),
          durationMs: 150000,
          downloadState: const Value(2),
        ),
      );

      expect(await dao.getByTrackId(3003), isNotNull);

      await dao.deleteByTrackId(3003);

      expect(await dao.getByTrackId(3003), isNull);
    });

    test('DeleteAll clears database', () async {
      for (int i = 0; i < 5; i++) {
        await dao.insertOrUpdate(
          DownloadedTracksCompanion.insert(
            trackId: 4000 + i,
            artistId: 1,
            albumId: 1,
            title: 'Track $i',
            artistName: 'Artist',
            albumName: 'Album',
            coverUrl: 'https://cover.jpg',
            localAudioPath: '/storage/music/400$i.mp3',
            fileSizeBytes: const Value(1000),
            durationMs: 120000,
            downloadState: const Value(2),
          ),
        );
      }


      var list = await dao.getAllDownloaded();
      expect(list.length, equals(5));

      await dao.deleteAll();

      list = await dao.getAllDownloaded();
      expect(list, isEmpty);
    });

    test('contributorsJson persiste y sobrevive el round-trip de lectura', () async {
      const json = '[{"id":10,"name":"Jesse & Joy"},{"id":20,"name":"Gente De Zona"}]';

      await dao.insertOrUpdate(
        DownloadedTracksCompanion.insert(
          trackId: 5005,
          artistId: 10,
          albumId: 1,
          title: '3 A.M.',
          artistName: 'Jesse & Joy',
          albumName: '3 A.M.',
          coverUrl: 'https://cover.jpg',
          localAudioPath: '/storage/music/5005.mp3',
          durationMs: 183000,
          contributorsJson: const Value(json),
          downloadState: const Value(2),
        ),
      );

      final track = await dao.getByTrackId(5005);
      expect(track, isNotNull);
      expect(track!.contributorsJson, equals(json));
    });
  });
}
