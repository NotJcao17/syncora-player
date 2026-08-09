import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/sync/sync_cache_manager.dart';

void main() {
  group('SyncCacheManager Tests', () {
    late SyncCacheManager cacheManager;

    setUp(() {
      cacheManager = SyncCacheManager();
    });

    test('isExpired returns true for non-existent key', () {
      expect(cacheManager.isExpired('library'), isTrue);
    });

    test('markSynced marks key as non-expired', () {
      cacheManager.markSynced('library');
      expect(cacheManager.isExpired('library'), isFalse);
    });

    test('invalidate removes key and makes it expired again', () {
      cacheManager.markSynced('library');
      expect(cacheManager.isExpired('library'), isFalse);

      cacheManager.invalidate('library');
      expect(cacheManager.isExpired('library'), isTrue);
    });

    test('isExpired respects customTtl', () async {
      cacheManager.markSynced('short_ttl_key');
      expect(
        cacheManager.isExpired('short_ttl_key', customTtl: const Duration(milliseconds: 10)),
        isFalse,
      );

      await Future.delayed(const Duration(milliseconds: 20));
      expect(
        cacheManager.isExpired('short_ttl_key', customTtl: const Duration(milliseconds: 10)),
        isTrue,
      );
    });

    test('isExpired returns true after default TTL duration expires', () {
      final shortCacheManager = SyncCacheManager(defaultTtl: const Duration(milliseconds: 10));
      shortCacheManager.markSynced('test_key');
      expect(shortCacheManager.isExpired('test_key'), isFalse);

      return Future.delayed(const Duration(milliseconds: 20), () {
        expect(shortCacheManager.isExpired('test_key'), isTrue);
      });
    });
  });
}
