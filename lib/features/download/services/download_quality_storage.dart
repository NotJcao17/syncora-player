import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/download_quality.dart';

abstract class DownloadQualityStorage {
  Future<DownloadQuality> getQuality();
  Future<void> setQuality(DownloadQuality quality);
}

class SecureDownloadQualityStorage implements DownloadQualityStorage {
  static const _key = 'syncora_download_quality_v1';
  final FlutterSecureStorage _storage;

  SecureDownloadQualityStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<DownloadQuality> getQuality() async {
    try {
      final val = await _storage.read(key: _key);
      return DownloadQuality.fromString(val);
    } catch (_) {
      return DownloadQuality.high;
    }
  }

  @override
  Future<void> setQuality(DownloadQuality quality) async {
    try {
      await _storage.write(key: _key, value: quality.name);
    } catch (_) {}
  }
}

class DownloadQualityNotifier extends Notifier<DownloadQuality> {
  late final DownloadQualityStorage _storage;
  bool _userExplicitlySet = false;

  @override
  DownloadQuality build() {
    _storage = ref.watch(downloadQualityStorageProvider);
    _userExplicitlySet = false;
    _loadInitial();
    return DownloadQuality.high;
  }

  Future<void> _loadInitial() async {
    final quality = await _storage.getQuality();
    if (!_userExplicitlySet) {
      state = quality;
    }
  }

  Future<void> setQuality(DownloadQuality quality) async {
    _userExplicitlySet = true;
    state = quality;
    await _storage.setQuality(quality);
  }
}

final downloadQualityStorageProvider = Provider<DownloadQualityStorage>((ref) {
  return SecureDownloadQualityStorage();
});

final downloadQualityProvider =
    NotifierProvider<DownloadQualityNotifier, DownloadQuality>(() {
  return DownloadQualityNotifier();
});
