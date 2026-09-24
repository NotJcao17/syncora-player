import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncora_player/core/settings/app_settings_store.dart';
import 'package:syncora_player/features/download/download_provider.dart';
import 'package:syncora_player/features/player/player_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer containerFor(AppSettingsStore store) {
    final container = ProviderContainer(
      overrides: [appSettingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('defaults: radio on, crossfade off, wifi-only on, quality high', () {
    final container = containerFor(AppSettingsStore.inMemory());
    expect(container.read(radioEnabledProvider), isTrue);
    expect(container.read(crossfadeDurationProvider), Duration.zero);
    expect(container.read(downloadWifiOnlyProvider), isTrue);
    expect(container.read(downloadQualityProvider), DownloadQuality.high);
  });

  test('settings survive a restart (new container over the same prefs)', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    final first = containerFor(await AppSettingsStore.load());
    first.read(radioEnabledProvider.notifier).set(false);
    first.read(crossfadeDurationProvider.notifier).set(const Duration(seconds: 4));
    first.read(downloadWifiOnlyProvider.notifier).set(false);
    await first.read(downloadQualityProvider.notifier).setQuality(DownloadQuality.medium);
    await Future<void>.delayed(Duration.zero);

    final second = containerFor(await AppSettingsStore.load());
    expect(second.read(radioEnabledProvider), isFalse);
    expect(second.read(crossfadeDurationProvider), const Duration(seconds: 4));
    expect(second.read(downloadWifiOnlyProvider), isFalse);
    expect(second.read(downloadQualityProvider), DownloadQuality.medium);
  });

  test('migrates the legacy quality from secure storage once', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'syncora_download_quality_v1': 'low'});

    final container = containerFor(await AppSettingsStore.load());
    expect(container.read(downloadQualityProvider), DownloadQuality.low);
    expect(await const FlutterSecureStorage().read(key: 'syncora_download_quality_v1'), isNull);
  });
}
