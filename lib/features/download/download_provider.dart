import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';


import '../../core/cache/cover_cache_service.dart';
import '../../core/extraction/extraction_provider.dart';
import '../../data/local_db/database_provider.dart';
import '../../data/local_db/syncora_database.dart';
import 'download_service.dart';

export 'models/download_quality.dart';
export 'services/download_quality_storage.dart';

final downloadWifiOnlyProvider = StateProvider<bool>((ref) => true);

final watchDownloadedTrackProvider = StreamProvider.family<DownloadedTrack?, int>((ref, trackId) {
  final dao = ref.watch(downloadedTrackDaoProvider);
  return dao.watchByTrackId(trackId);
});

final watchAllDownloadedTracksProvider = StreamProvider<List<DownloadedTrack>>((ref) {
  final dao = ref.watch(downloadedTrackDaoProvider);
  return dao.watchAllDownloaded();
});

final downloadServiceProvider = Provider<DownloadService>((ref) {
  final dao = ref.watch(downloadedTrackDaoProvider);
  final extractionService = ref.watch(extractionServiceProvider);
  final coverCacheService = ref.watch(coverCacheServiceProvider);
  final wifiOnly = ref.watch(downloadWifiOnlyProvider);

  final service = DownloadService(
    dao: dao,
    extractionService: extractionService,
    coverCacheService: coverCacheService,
    ref: ref,
  );

  service.setWifiOnly(wifiOnly);
  service.cleanupInterruptedDownloads();
  ref.onDispose(() => service.dispose());
  return service;
});

