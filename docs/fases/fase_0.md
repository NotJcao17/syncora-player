# Resumen y Contexto — Fase 0: Setup y Arquitectura Base

Este documento contiene el registro de desarrollo y contexto técnico de la **Fase 0** de Syncora Player.

---

## 🎯 Objetivos Cumplidos

1. **Inicialización de Proyecto Flutter:**
   - Nombre: `syncora_player` (`com.syncora`).
   - Plataformas objetivo: **Windows** y **Android** exclusivamente.

2. **Estructura de Carpetas (Feature-First + Clean Architecture):**
   ```text
   lib/
   ├── core/
   │   ├── config/
   │   ├── theme/
   │   ├── utils/
   │   └── errors/
   ├── data/
   │   ├── models/
   │   ├── supabase/
   │   ├── local_db/
   │   └── apis/
   ├── features/
   │   ├── auth/
   │   ├── player/
   │   ├── library/
   │   ├── search/
   │   └── download/
   └── main.dart
   ```

3. **Dependencias Configuradas:**
   - **State & DI:** `flutter_riverpod`, `riverpod_annotation`, `build_runner`, `riverpod_generator`.
   - **Navegación:** `go_router`.
   - **Audio:** `just_audio` & `audio_service` (Android), `media_kit`, `media_kit_libs_windows_audio`, `smtc_windows` (Windows).
   - **Base de Datos & Red:** `drift`, `sqlite3_flutter_libs`, `sqflite_common_ffi`, `path_provider`, `dio`, `supabase_flutter`.
   - **UI & Tema:** `cached_network_image`, `lucide_icons_flutter`, `google_fonts` (Plus Jakarta Sans).
   - **Seguridad & Storage:** `flutter_secure_storage`, `flutter_dotenv`.

4. **Variables de Entorno (.env):**
   - Archivo `.env.example` versionado en Git.
   - Archivo `.env` ignorado en `.gitignore` y configurado con la URL y anon/publishable key reales del proyecto Supabase `njkfudsyfzdkdvwizdag`.

5. **Entry Point y Tema Visual:**
   - `AppTheme.darkTheme` implementado con la paleta oficial (`#181C27` background, `#1E2633` surface, `#FFFFFF` primary, `#A0ABBA` secondary, `#7F8C9D` muted) y tipografía *Plus Jakarta Sans*.
   - Inicialización de `sqflite_common_ffi` en Windows.
   - Control de `MediaKit.ensureInitialized()` restringido estrictamente a `Platform.isWindows` (evitando crasheos por ausencia de `libmpv.so` en Android).

6. **Permisos Android 14+:**
   - Declarados permisos `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` y `FOREGROUND_SERVICE_DATA_SYNC` en `AndroidManifest.xml`.
   - `minSdk` establecido en 21 y `targetSdk` en 34 en Gradle.

---

## 🛠️ Correcciones Notables en Fase 0

- **MediaKit en Android:** Se corrigió el condicional de inicialización en `main.dart`. `MediaKit` requiere binarios nativos de `libmpv` que solo están presentes en Windows; en Android se utiliza `just_audio` (ExoPlayer). La inicialización quedó fijada a `if (!kIsWeb && Platform.isWindows)`.
- **MSVC C++ ATL en Windows:** Se aplicó una solución nativa sin dependencias de cabeceras ATL en el plugin de almacenamiento seguro en Windows, garantizando compilaciones limpias sin requerir elevación de instaladores Visual Studio.

---

## 🧪 Pruebas de Fase 0

- **Windows:** `flutter build windows --debug` ➔ Compilación exitosa (`syncora_player.exe`).
- **Android:** `flutter build apk --debug` ➔ Compilación exitosa (`app-debug.apk`).
- **Flutter Analyze:** 0 errores y 0 advertencias de analisis.
