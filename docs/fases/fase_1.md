# Resumen y Contexto — Fase 1: El Motor Resiliente (Spike Técnico)

Este documento registra los logros y decisiones de arquitectura de la **Fase 1** de Syncora Player.

---

## 🎯 Objetivos Cumplidos

1. **Inclusión de Dependencia `flutter_js`:**
   - Agregado `flutter_js` en `pubspec.yaml` (v0.8.7).
   - Ejecutado `flutter pub get` limpio sin conflictos.

2. **Arquitectura del Isolate de Extracción:**
   - Creado `ExtractionIsolate` (`lib/core/extraction/extraction_isolate.dart`), que se ejecuta en un `Isolate.spawn` secundario y persistente durante toda la sesión.
   - Inicialización obligatoria de `BackgroundIsolateBinaryMessenger` con `RootIsolateToken`.
   - Modelado de `ExtractionRequest` y `ExtractionResult` (`ExtractionSuccess` / `ExtractionFailure` con `ExtractionError`).

3. **Puente `dartFetchBridge`:**
   - Creado `DartFetchBridge` (`lib/core/extraction/dart_fetch_bridge.dart`) utilizando `Dio`:
     - Manejo de redirecciones HTTP (hasta 5 niveles).
     - Persistencia de cookies/sesión entre peticiones.
     - Decodificación automática de gzip y brotli.
     - Preservación estricta de headers requeridos por YouTube (Pitfall #13).

4. **Inyección de Polyfills JS:**
   - Creado `JsBundleLoader` (`lib/core/extraction/js_bundle_loader.dart`) que provee polyfills puros en QuickJS:
     - `TextEncoder` / `TextDecoder` (UTF-8).
     - `URL` / `URLSearchParams`.
     - `setTimeout` / `clearTimeout` (puente a `Future.delayed`).
     - `console.log` / `console.error` (puente a `debugPrint`).
     - `fetch` (puente asíncrono a `DartFetchBridge`).
   - Creado asset placeholder en `assets/js/youtubei.bundle.js` y registrado en `pubspec.yaml`.

5. **Lógica de Extracción con Clientes PoToken-Free:**
   - Implementado en `ExtractionIsolate` la secuencia de fallback de clientes (Pitfall #18):
     1. `tv`
     2. `tv_downgraded`
     3. `android_vr`

6. **Guard Anti-Bucle 403 (CRÍTICO):**
   - Creado `RetryPolicy` (`lib/core/extraction/retry_policy.dart`):
     - Regla estricta: Máximo 1 reintento ante 403 o error de red.
     - Pausa inmediata en el 2º fallo emitiendo `ExtractionError.rateLimited`.
     - `ExtractionError.notFound` no reintenta.

7. **Fachada `ExtractionService` y Providers:**
   - Creados `ExtractionServiceReal` y `ExtractionServiceMock` (devuelve MP3 público en web `kIsWeb`, Pitfall #6).
   - Inyectado vía Riverpod en `extractionServiceProvider` (`lib/core/extraction/extraction_provider.dart`).

8. **Pantalla de Debug Temporal (`/debug`):**
   - Creada `ExtractionDebugScreen` (`lib/features/player/debug/extraction_debug_screen.dart`) marcada con `// TODO: Eliminar en Fase 3`.
   - Permite probar la extracción de cualquier `videoId` con log en pantalla y reproducción con `just_audio` (Android) o `media_kit` (Windows).
   - Enrutada en `GoRouter` (`/debug`).

9. **Unit Tests Automatizados:**
   - `test/core/extraction/retry_policy_test.dart` (Guard 403).
   - `test/core/extraction/dart_fetch_bridge_test.dart` (Redirecciones, GZIP, Timeouts).

---

## 🛠️ Decisiones de Arquitectura

- **Separación de Isolates:** El motor de QuickJS corre 100% aislado del Main Isolate de la UI. La desencriptación de firmas y parsing de respuestas de Innertube no provoca pérdidas de frames (jank) en Flutter.
- **Bypass en Web (`kIsWeb`):** Para evitar crasheos por binarios FFI o Isolates en el navegador, `ExtractionServiceMock` suministra una URL de prueba, permitiendo validar la interfaz de usuario en Chrome.

---

## 🧪 Pruebas de la Fase 1

- [x] **Unit tests de RetryPolicy y Guard 403:** Pasaron exitosamente.
- [x] **Unit tests del Puente dartFetch:** Pasaron exitosamente.
- [x] **Flutter Analyze:** 0 errores.
