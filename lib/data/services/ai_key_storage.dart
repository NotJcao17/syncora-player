import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Fase 7.E.7/7.E.8 -- almacenamiento de la llave BYOK ("Bring Your Own Key")
/// de Gemini que el usuario puede traer opcionalmente.
///
/// Documento Maestro §4.3, punto 3 / plan 7.E: si el usuario trae su propia
/// llave, se guarda EXCLUSIVAMENTE en local con `flutter_secure_storage`
/// (nunca en un provider en memoria plano, nunca en Supabase). Esta interfaz
/// existe para poder inyectar un doble en memoria en los tests de
/// [AiAssistantService] sin tocar el keychain/keystore real de la
/// plataforma (que no está disponible en `flutter test`).
abstract class AiKeyStorage {
  Future<String?> getKey();
  Future<void> setKey(String key);
  Future<void> deleteKey();
}

class SecureAiKeyStorage implements AiKeyStorage {
  // Nombre de la entrada en el almacenamiento seguro. Un solo valor: la app
  // solo soporta una llave BYOK por dispositivo (no por proveedor), ya que
  // hoy solo existe integración con Gemini.
  static const _storageKey = 'gemini_byok_api_key';

  final FlutterSecureStorage _storage;

  SecureAiKeyStorage({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> getKey() async {
    final value = await _storage.read(key: _storageKey);
    if (value == null || value.trim().isEmpty) return null;
    return value;
  }

  @override
  Future<void> setKey(String key) => _storage.write(key: _storageKey, value: key.trim());

  @override
  Future<void> deleteKey() => _storage.delete(key: _storageKey);
}

final aiKeyStorageProvider = Provider<AiKeyStorage>((ref) => SecureAiKeyStorage());

/// Refleja si hay una llave BYOK guardada, para que la UI de Configuración
/// (7.E.8) pueda reaccionar (mostrar el campo vacío vs. "llave guardada" +
/// botón borrar) sin tener que leer el storage seguro directamente. Se
/// invalida manualmente (`ref.invalidate(aiByokKeyPresentProvider)`) tras
/// guardar o borrar, mismo patrón que `profileProvider` en auth_provider.dart.
final aiByokKeyPresentProvider = FutureProvider<bool>((ref) async {
  final storage = ref.watch(aiKeyStorageProvider);
  final key = await storage.getKey();
  return key != null;
});
