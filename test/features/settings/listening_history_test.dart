import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';

void main() {
  late SyncoraDatabase db;

  setUp(() {
    db = SyncoraDatabase(
      DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true),
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('ListeningHistoryDao Tests', () {
    test('recordEntry and watchRecentHistory emits recent listening entries in desc order', () async {
      final dao = db.listeningHistoryDao;

      await dao.recordEntry(
        trackId: 101,
        artistId: 201,
        albumId: 301,
        durationListenedMs: 45000,
        genre: 'Rock',
      );

      await dao.recordEntry(
        trackId: 102,
        artistId: 202,
        albumId: 302,
        durationListenedMs: 60000,
        genre: 'Pop',
      );

      final history = await dao.getRecentHistory();
      expect(history.length, equals(2));
      expect(history.first.trackId, equals(102));
      expect(history.last.trackId, equals(101));

      final streamResult = await dao.watchRecentHistory().first;
      expect(streamResult.length, equals(2));
      expect(streamResult.first.trackId, equals(102));
    });

    test('deleteAll clears all recorded history entries', () async {
      final dao = db.listeningHistoryDao;

      await dao.recordEntry(
        trackId: 101,
        artistId: 201,
        albumId: 301,
        durationListenedMs: 45000,
      );

      expect((await dao.getRecentHistory()).length, equals(1));

      await dao.deleteAll();
      expect((await dao.getRecentHistory()), isEmpty);
    });
  });
}
