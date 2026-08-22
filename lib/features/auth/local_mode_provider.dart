import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/connectivity_service.dart';
import 'services/local_mode_storage.dart';

/// Fase 7.I.1 -- almacenamiento inyectable de [LocalModeStorage], mismo
/// patrón que `aiKeyStorageProvider` (7.E.8): se sobreescribe en
/// `main.dart` con la instancia real ya usada para precargar el estado
/// inicial (ver [localModeProvider]), y en tests con un doble en memoria.
final localModeStorageProvider = Provider<LocalModeStorage>((ref) => SecureLocalModeStorage());

/// Fase 7.I.1 -- `localModeProvider`: si el usuario eligió trabajar sin
/// cuenta (D-23). El valor inicial se precarga en `main.dart` ANTES de
/// `runApp` (vía `overrideWith` sobre este provider) para que esté
/// disponible de forma síncrona desde el primer frame -- el `redirect` de
/// `app_router.dart` es una función síncrona y no puede esperar un
/// `FutureProvider`. En tests (que nunca ejecutan `main()`) arranca en
/// `false` sin tocar el storage real, a menos que un test lo overridee.
class LocalModeNotifier extends Notifier<bool> {
  LocalModeNotifier([this._initial = false]);

  final bool _initial;

  @override
  bool build() => _initial;

  /// D-23/7.I.3: el usuario tocó "Usar sin cuenta" en `auth_screen.dart`.
  Future<void> enable() async {
    state = true;
    await ref.read(localModeStorageProvider).setLocalMode(true);
  }

  /// D-25/7.I.10: migración local -> cuenta completada (exitosa o no --
  /// una vez que hay una sesión real, `currentUserProvider` manda en el
  /// gate del router de todos modos; esto solo evita que la UI de
  /// Configuración siga mostrando el bloque de "Modo local" después).
  Future<void> disable() async {
    state = false;
    await ref.read(localModeStorageProvider).setLocalMode(false);
  }
}

final localModeProvider = NotifierProvider<LocalModeNotifier, bool>(LocalModeNotifier.new);

/// Fase 7.I.4: semilla de avatar en modo local, generada una sola vez
/// (`getOrCreateAvatarSeed`). Se invalida manualmente tras elegir un
/// avatar nuevo, mismo patrón que `aiByokKeyPresentProvider`.
final localAvatarSeedProvider = FutureProvider<String>((ref) {
  return ref.watch(localModeStorageProvider).getOrCreateAvatarSeed();
});

/// D-24 -- el refactor central de 7.I (H-5): `canEdit = isLocalMode ||
/// isConnected`, en vez de solo `isConnected`. Extraída como función pura
/// (mismo motivo que `computeAuthRedirect` en `app_router.dart`, 7.I.12):
/// testear la combinación de un `Provider` derivado contra un
/// `StreamProvider` overrideado es innecesariamente fiable de timing
/// (esperar a que el stream emita, disposal ordenado, etc.) para una regla
/// de 2 líneas -- la lógica real vive acá, testeable sin Riverpod en
/// absoluto.
bool computeCanEdit({required bool isLocalMode, required bool isConnected}) {
  return isLocalMode || isConnected;
}

/// Sin nube que mantener consistente en modo local, la restricción
/// Online-First no aplica.
final canEditProvider = Provider<bool>((ref) {
  final isLocalMode = ref.watch(localModeProvider);
  final isConnected = ref.watch(isConnectedProvider).value ?? true;
  return computeCanEdit(isLocalMode: isLocalMode, isConnected: isConnected);
});
