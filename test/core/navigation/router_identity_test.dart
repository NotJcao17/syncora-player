import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/navigation/app_router.dart';
import 'package:syncora_player/features/auth/local_mode_provider.dart';
import 'package:syncora_player/features/auth/services/local_mode_storage.dart';

class _FakeLocalModeStorage implements LocalModeStorage {
  bool _value = false;
  String? _seed;

  @override
  Future<bool> getIsLocalMode() async => _value;

  @override
  Future<void> setLocalMode(bool value) async => _value = value;

  @override
  Future<String> getOrCreateAvatarSeed() async => _seed ??= 'seed';

  @override
  Future<void> setAvatarSeed(String seed) async => _seed = seed;
}

/// Regresión del bug real de pruebas manuales: `SyncoraApp` hace
/// `ref.watch(appRouterProvider)`, así que si este provider se reconstruye
/// entrega un `GoRouter` NUEVO a `MaterialApp.router` -- y un `GoRouter`
/// nuevo arranca en su `initialLocation` ('/'), saltándose
/// `computeAuthRedirect`. Eso destruía la `AuthScreen` en pleno flujo de
/// resolución de datos locales y dejaba el flag de modo local pegado en
/// `true` con una sesión real ya creada, sin salida desde la UI.
///
/// El invariante: cambiar el estado que el redirect consulta NO debe
/// producir una instancia distinta.
void main() {
  test('cambiar localModeProvider no reconstruye el GoRouter', () async {
    final container = ProviderContainer(
      overrides: [
        localModeStorageProvider.overrideWithValue(_FakeLocalModeStorage()),
      ],
    );
    addTearDown(container.dispose);

    final before = container.read(appRouterProvider);

    await container.read(localModeProvider.notifier).enable();
    expect(container.read(localModeProvider), isTrue);
    expect(identical(container.read(appRouterProvider), before), isTrue);

    await container.read(localModeProvider.notifier).disable();
    expect(container.read(localModeProvider), isFalse);
    expect(identical(container.read(appRouterProvider), before), isTrue);
  });
}
