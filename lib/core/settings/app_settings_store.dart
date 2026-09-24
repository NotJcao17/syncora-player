import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistencia de los ajustes de Configuración (radio, crossfade, Wi-Fi,
/// calidad de descarga).
///
/// Todos son **del dispositivo**, no de la cuenta: Wi-Fi y calidad dependen
/// del hardware/red de cada equipo, y así el modo local (7.I) se comporta
/// igual que con cuenta. Por eso la columna `profiles.download_wifi_only` de
/// Supabase queda sin uso a propósito.
///
/// Se carga una sola vez en `main.dart` antes de `runApp` y los getters son
/// síncronos: el controlador del reproductor lee radio/crossfade con
/// `ref.read` en cualquier momento, y no debe ver nunca el valor por defecto
/// mientras el real todavía se carga.
class AppSettingsStore {
  AppSettingsStore._(this._prefs);

  /// Sin disco: para tests y para el default del provider.
  AppSettingsStore.inMemory() : _prefs = null;

  static const radioEnabledKey = 'settings.radio_enabled';
  static const crossfadeSecondsKey = 'settings.crossfade_seconds';
  static const downloadWifiOnlyKey = 'settings.download_wifi_only';
  static const downloadQualityKey = 'settings.download_quality';

  /// Clave con la que la calidad vivía en `flutter_secure_storage` antes de
  /// que existiera este store. Se migra una vez y se borra.
  static const _legacyQualityKey = 'syncora_download_quality_v1';

  final SharedPreferences? _prefs;
  final Map<String, Object> _memory = {};

  static Future<AppSettingsStore> load({FlutterSecureStorage? secureStorage}) async {
    final prefs = await SharedPreferences.getInstance();
    final store = AppSettingsStore._(prefs);
    if (!prefs.containsKey(downloadQualityKey)) {
      try {
        final legacy = secureStorage ?? const FlutterSecureStorage();
        final value = await legacy.read(key: _legacyQualityKey);
        if (value != null) {
          await prefs.setString(downloadQualityKey, value);
          await legacy.delete(key: _legacyQualityKey);
        }
      } catch (_) {}
    }
    return store;
  }

  bool? getBool(String key) {
    final prefs = _prefs;
    if (prefs == null) return _memory[key] as bool?;
    return prefs.getBool(key);
  }

  int? getInt(String key) {
    final prefs = _prefs;
    if (prefs == null) return _memory[key] as int?;
    return prefs.getInt(key);
  }

  String? getString(String key) {
    final prefs = _prefs;
    if (prefs == null) return _memory[key] as String?;
    return prefs.getString(key);
  }

  Future<void> setBool(String key, bool value) async {
    final prefs = _prefs;
    if (prefs == null) {
      _memory[key] = value;
      return;
    }
    try {
      await prefs.setBool(key, value);
    } catch (_) {}
  }

  Future<void> setInt(String key, int value) async {
    final prefs = _prefs;
    if (prefs == null) {
      _memory[key] = value;
      return;
    }
    try {
      await prefs.setInt(key, value);
    } catch (_) {}
  }

  Future<void> setString(String key, String value) async {
    final prefs = _prefs;
    if (prefs == null) {
      _memory[key] = value;
      return;
    }
    try {
      await prefs.setString(key, value);
    } catch (_) {}
  }
}

/// Se sobreescribe en `main.dart` con la instancia ya cargada de disco.
final appSettingsStoreProvider = Provider<AppSettingsStore>((ref) => AppSettingsStore.inMemory());

/// Ajuste booleano persistido. `set` actualiza el estado y lo escribe en disco.
class BoolSettingNotifier extends Notifier<bool> {
  BoolSettingNotifier(this._key, this._defaultValue);

  final String _key;
  final bool _defaultValue;

  @override
  bool build() => ref.watch(appSettingsStoreProvider).getBool(_key) ?? _defaultValue;

  void set(bool value) {
    state = value;
    ref.read(appSettingsStoreProvider).setBool(_key, value);
  }
}
