import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/cache/cover_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CoverCacheService cacheService;

  setUp(() async {
    cacheService = CoverCacheService();
  });

  group('CoverCacheService LRU Cache Tests', () {
    test('Cache initial state is initialized', () async {
      expect(cacheService.currentSizeBytes, equals(0));
    });

    test('Clear cache resets size to zero', () async {
      await cacheService.clear();
      expect(cacheService.currentSizeBytes, equals(0));
    });
  });
}
