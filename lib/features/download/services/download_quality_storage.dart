import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/settings/app_settings_store.dart';
import '../models/download_quality.dart';

/// Calidad de las descargas nuevas. Persistida por dispositivo en
/// [AppSettingsStore] (antes vivía en `flutter_secure_storage`; el store la
/// migra una vez al arrancar).
class DownloadQualityNotifier extends Notifier<DownloadQuality> {
  @override
  DownloadQuality build() => DownloadQuality.fromString(
        ref.watch(appSettingsStoreProvider).getString(AppSettingsStore.downloadQualityKey),
      );

  Future<void> setQuality(DownloadQuality quality) async {
    state = quality;
    await ref.read(appSettingsStoreProvider).setString(AppSettingsStore.downloadQualityKey, quality.name);
  }
}

final downloadQualityProvider =
    NotifierProvider<DownloadQualityNotifier, DownloadQuality>(DownloadQualityNotifier.new);
