import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/auth/local_mode_provider.dart';
import 'package:syncora_player/features/auth/services/local_mode_storage.dart';

/// Doble en memoria de [LocalModeStorage] -- mismo patrón que los tests de
/// `AiKeyStorage` (7.E.8): el proyecto nunca testea `flutter_secure_storage`
/// real contra el canal de plataforma (no está disponible en `flutter
/// test`), así que la persistencia se verifica a nivel de contrato: llamar
/// [enable]/[disable] debe reflejarse en lo que el storage guarda.
class FakeLocalModeStorage implements LocalModeStorage {
  bool _isLocalMode = false;
  String? _seed;

  @override
  Future<bool> getIsLocalMode() async => _isLocalMode;

  @override
  Future<void> setLocalMode(bool value) async => _isLocalMode = value;

  @override
  Future<String> getOrCreateAvatarSeed() async {
    _seed ??= 'fake-seed';
    return _seed!;
  }

  @override
  Future<void> setAvatarSeed(String seed) async => _seed = seed;
}

void main() {
  group('localModeProvider / LocalModeNotifier (Fase 7.I.1/7.I.15)', () {
    test('arranca en el valor inicial precargado (simula el restart de la app, 7.I.15)', () {
      final container = ProviderContainer(
        overrides: [
          localModeProvider.overrideWith(() => LocalModeNotifier(true)),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(localModeProvider), isTrue);
    });

    test('enable() marca el estado true y lo persiste en el storage (7.I.1/7.I.3)', () async {
      final fakeStorage = FakeLocalModeStorage();
      final container = ProviderContainer(
        overrides: [localModeStorageProvider.overrideWithValue(fakeStorage)],
      );
      addTearDown(container.dispose);

      expect(container.read(localModeProvider), isFalse);

      await container.read(localModeProvider.notifier).enable();

      expect(container.read(localModeProvider), isTrue);
      // Lo que "sobreviviría" a un restart real (7.I.15): lo que quedó
      // guardado en el storage inyectado.
      expect(await fakeStorage.getIsLocalMode(), isTrue);
    });

    test('disable() marca el estado false y lo persiste (7.I.10, tras migrar a cuenta)', () async {
      final fakeStorage = FakeLocalModeStorage()..setLocalMode(true);
      final container = ProviderContainer(
        overrides: [
          localModeStorageProvider.overrideWithValue(fakeStorage),
          localModeProvider.overrideWith(() => LocalModeNotifier(true)),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(localModeProvider), isTrue);

      await container.read(localModeProvider.notifier).disable();

      expect(container.read(localModeProvider), isFalse);
      expect(await fakeStorage.getIsLocalMode(), isFalse);
    });
  });

  group('computeCanEdit (Fase 7.I.7/7.I.14, D-24: canEdit = isLocalMode || isConnected)', () {
    test('modo local + SIN conexión -> canEdit sigue siendo true (7.I.14, la regresión que 7.I.7 podía introducir)', () {
      expect(computeCanEdit(isLocalMode: true, isConnected: false), isTrue);
    });

    test('sin cuenta (no modo local) + sin conexión -> canEdit es false (comportamiento pre-7.I intacto)', () {
      expect(computeCanEdit(isLocalMode: false, isConnected: false), isFalse);
    });

    test('con cuenta + con conexión -> canEdit es true', () {
      expect(computeCanEdit(isLocalMode: false, isConnected: true), isTrue);
    });

    test('modo local + con conexión -> canEdit es true', () {
      expect(computeCanEdit(isLocalMode: true, isConnected: true), isTrue);
    });
  });
}
