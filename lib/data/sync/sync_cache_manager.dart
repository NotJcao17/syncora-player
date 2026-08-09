import 'package:flutter_riverpod/flutter_riverpod.dart';

class SyncCacheManager {
  final Map<String, DateTime> _lastSyncedMap = {};
  final Duration defaultTtl;

  SyncCacheManager({this.defaultTtl = const Duration(minutes: 5)});

  bool isExpired(String key, {Duration? customTtl}) {
    final lastSynced = _lastSyncedMap[key];
    if (lastSynced == null) return true;
    final ttl = customTtl ?? defaultTtl;
    return DateTime.now().difference(lastSynced) > ttl;
  }

  void markSynced(String key) {
    _lastSyncedMap[key] = DateTime.now();
  }

  void invalidate(String key) {
    _lastSyncedMap.remove(key);
  }
}

final syncCacheManagerProvider = Provider<SyncCacheManager>((ref) {
  return SyncCacheManager();
});
