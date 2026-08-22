import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Fase 7.I -- persistencia del modo local / sin cuenta (D-23, D-24).
///
/// El proyecto todavía no tiene `shared_preferences` (varios providers de
/// Configuración lo documentan explícitamente, ej. `radioEnabledProvider`
/// en `player_providers.dart`) — en vez de agregar una dependencia nueva
/// solo para dos strings, se reusa `flutter_secure_storage`, que ya es
/// dependencia del proyecto desde 7.E.8 (BYOK) y ya tiene el patrón
/// exacto que necesita esta interfaz: [AiKeyStorage] en
/// `data/services/ai_key_storage.dart`.
abstract class LocalModeStorage {
  Future<bool> getIsLocalMode();
  Future<void> setLocalMode(bool value);

  /// Semilla de DiceBear para el avatar en modo local (7.I.4) -- se genera
  /// una sola vez, la primera vez que hace falta, y se reusa después. En
  /// modo cuenta el seed vive en la tabla `profiles` de Supabase
  /// (`auth_provider.dart`); acá es puramente local porque no hay ninguna
  /// fila de servidor con la que asociarlo.
  Future<String> getOrCreateAvatarSeed();

  /// Sobrescribe el seed elegido por el usuario en el selector de avatar
  /// (7.I.4) -- mismo hook que en modo cuenta usa
  /// `AvatarSelectorSheet.onAvatarSelected`, pero persistiendo acá en vez
  /// de en la tabla `profiles`.
  Future<void> setAvatarSeed(String seed);
}

class SecureLocalModeStorage implements LocalModeStorage {
  static const _localModeKey = 'local_mode_enabled';
  static const _avatarSeedKey = 'local_mode_avatar_seed';

  final FlutterSecureStorage _storage;

  SecureLocalModeStorage({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<bool> getIsLocalMode() async {
    final value = await _storage.read(key: _localModeKey);
    return value == 'true';
  }

  @override
  Future<void> setLocalMode(bool value) => _storage.write(key: _localModeKey, value: value.toString());

  @override
  Future<String> getOrCreateAvatarSeed() async {
    final existing = await _storage.read(key: _avatarSeedKey);
    if (existing != null && existing.trim().isNotEmpty) return existing;

    final seed = _generateRandomSeed();
    await setAvatarSeed(seed);
    return seed;
  }

  @override
  Future<void> setAvatarSeed(String seed) => _storage.write(key: _avatarSeedKey, value: seed);

  // UUID sin agregar el paquete `uuid` como dependencia directa (solo
  // llega transitivamente hoy, vía otro paquete) -- 16 bytes aleatorios en
  // hexadecimal son más que suficientes como semilla de DiceBear, no hace
  // falta el formato canónico de UUID para este uso.
  String _generateRandomSeed() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
