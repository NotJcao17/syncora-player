import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/cache/cover_cache_service.dart';
import 'package:syncora_player/core/extraction/extraction_service.dart';
import 'package:syncora_player/core/extraction/models/extraction_request.dart';
import 'package:syncora_player/data/local_db/daos/downloaded_track_dao.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/features/download/download_provider.dart';
import 'package:syncora_player/features/download/download_service.dart';
import 'package:syncora_player/features/player/player_models.dart';

class MockDownloadQualityStorage implements DownloadQualityStorage {
  DownloadQuality _quality = DownloadQuality.high;

  @override
  Future<DownloadQuality> getQuality() async => _quality;

  @override
  Future<void> setQuality(DownloadQuality quality) async {
    _quality = quality;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DownloadQuality Model Tests', () {
    test('DownloadQuality.fromString parses correctly with fallback to high', () {
      expect(DownloadQuality.fromString('high'), DownloadQuality.high);
      expect(DownloadQuality.fromString('medium'), DownloadQuality.medium);
      expect(DownloadQuality.fromString('low'), DownloadQuality.low);
      expect(DownloadQuality.fromString('invalid_value'), DownloadQuality.high);
      expect(DownloadQuality.fromString(null), DownloadQuality.high);
    });

    test('DownloadQuality properties match expectations', () {
      expect(DownloadQuality.high.label, 'Alta');
      expect(DownloadQuality.high.bitrateDescription, '~160-256 kbps');
      expect(DownloadQuality.medium.label, 'Normal');
      expect(DownloadQuality.medium.bitrateDescription, '~128 kbps');
      expect(DownloadQuality.low.label, 'Baja (Ahorro)');
      expect(DownloadQuality.low.bitrateDescription, '~64-96 kbps');
    });

    test('ExtractionRequest serializes and deserializes quality field', () {
      const req = ExtractionRequest(
        videoId: 'abc123xyz',
        requestId: 'req_001',
        quality: 'medium',
      );

      final json = req.toJson();
      expect(json['quality'], 'medium');

      final reconstructed = ExtractionRequest.fromJson(json);
      expect(reconstructed.quality, 'medium');
      expect(reconstructed.videoId, 'abc123xyz');
    });
  });

  group('DownloadQualityStorage & Notifier Tests', () {
    test('DownloadQualityNotifier updates state and saves to storage', () async {
      final mockStorage = MockDownloadQualityStorage();
      final container = ProviderContainer(
        overrides: [
          downloadQualityStorageProvider.overrideWithValue(mockStorage),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(downloadQualityProvider), DownloadQuality.high);

      await container.read(downloadQualityProvider.notifier).setQuality(DownloadQuality.low);
      expect(container.read(downloadQualityProvider), DownloadQuality.low);
      expect(await mockStorage.getQuality(), DownloadQuality.low);

      await container.read(downloadQualityProvider.notifier).setQuality(DownloadQuality.medium);
      expect(container.read(downloadQualityProvider), DownloadQuality.medium);
      expect(await mockStorage.getQuality(), DownloadQuality.medium);
    });
  });

  group('DownloadService Cleanup & Batch Result Tests', () {
    late SyncoraDatabase db;
    late DownloadedTrackDao dao;
    late ExtractionServiceMock extractionService;
    late CoverCacheService coverCacheService;
    late ProviderContainer container;

    setUp(() {
      db = SyncoraDatabase(NativeDatabase.memory());
      dao = db.downloadedTrackDao;
      extractionService = ExtractionServiceMock();
      coverCacheService = CoverCacheService();
      container = ProviderContainer(
        overrides: [
          downloadQualityProvider.overrideWith(() => DownloadQualityNotifier()),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('cleanupInterruptedDownloads deletes orphan in-progress records (state 1)', () async {
      // Insert an in-progress track (state 1) and a completed track (state 2)
      await dao.insertOrUpdate(
        DownloadedTracksCompanion.insert(
          trackId: 101,
          artistId: 1,
          albumId: 1,
          title: 'Interrupted Track',
          artistName: 'Artist A',
          albumName: 'Album A',
          coverUrl: 'http://cover.jpg',
          localAudioPath: 'temp/audio/101.mp4',
          durationMs: 180000,
          downloadState: const Value(1), // downloading / interrupted
        ),
      );

      final service = DownloadService(
        dao: dao,
        extractionService: extractionService,
        coverCacheService: coverCacheService,
      );

      expect(await dao.getByTrackId(101), isNotNull);

      await service.cleanupInterruptedDownloads();

      // State 1 must have been deleted from DB
      expect(await dao.getByTrackId(101), isNull);
    });

    test('downloadTracks correctly counts pending vs already downloaded tracks', () async {
      // Pre-populate track 201 as already downloaded (state 2)
      await dao.insertOrUpdate(
        DownloadedTracksCompanion.insert(
          trackId: 201,
          artistId: 1,
          albumId: 1,
          title: 'Already Downloaded',
          artistName: 'Artist A',
          albumName: 'Album A',
          coverUrl: 'http://cover.jpg',
          localAudioPath: 'temp/audio/201.mp4',
          durationMs: 180000,
          downloadState: const Value(2), // completed
        ),
      );

      final service = DownloadService(
        dao: dao,
        extractionService: extractionService,
        coverCacheService: coverCacheService,
      );

      const track1 = SyncoraTrack(
        id: '201',
        title: 'Already Downloaded',
        artist: 'Artist A',
      );

      final result = await service.downloadTracks([track1]);

      expect(result.totalCount, 1);
      expect(result.pendingCount, 0);
      expect(result.alreadyDownloadedCount, 1);
      expect(result.successCount, 1);
      expect(result.failedCount, 0);
      expect(result.isSuccess, isTrue);
    });
  });
}
