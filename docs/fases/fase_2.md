# Resumen y Contexto — Fase 2: Audio State y Controles del SO

Este documento registra los logros, arquitectura final, pruebas realizadas y decisiones tomadas durante la **Fase 2** de Syncora Player.

---

## 🎯 Objetivos Cumplidos

1. **Abstracción Agnóstica de Motor de Audio (`AudioEngine`):**
   - Implementado en `lib/features/player/audio_engine/audio_engine_state.dart`.
   - `JustAudioEngine` (`lib/features/player/audio_engine/just_audio_engine.dart`) para Android con soporte de headers HTTP nativos (`AudioSource.uri`).
   - `MediaKitEngine` (`lib/features/player/audio_engine/media_kit_engine.dart`) para Windows (`libmpv`) con soporte de headers HTTP (`Media(httpHeaders:)`).
   - `AudioEngineFactory` (`createAudioEngine()`) para instanciación limpia por plataforma.

2. **Controlador Central del Reproductor (`SyncoraPlayerController`):**
   - Implementado en `lib/features/player/syncora_player_controller.dart`.
   - Única fuente de la verdad para la cola de reproducción (`List<SyncoraTrack>`), modos (repeat, shuffle, skip silence), posición y estado del motor.
   - Integrado con `RetryPolicy` (Fase 1) para aplicar el **Guard 403**: máximo 1 reintento ante errores de red o 403, seguido de pausa inmediata; auto-skip ante errores lógicos (`notFound`).

3. **Controles del Sistema Operativo (Android & Windows):**
   - **Android (`SyncoraAudioHandler`):** `lib/features/player/os_controls/syncora_audio_handler.dart` extending `BaseAudioHandler` con `SeekHandler`. Sincroniza `PlaybackState`, `MediaItem` y `queue` con las notificaciones y lockscreen de Android. Manifiesto actualizado con `AudioServiceActivity`, `<service>` para `AudioService` (`foregroundServiceType="mediaPlayback"`) y `<receiver>` para `MediaButtonReceiver`.
   - **Windows (`WindowsMediaControls`):** `lib/features/player/os_controls/windows_media_controls.dart` envolviendo `SMTCWindows`. Muestra metadatos y timeline throttled en la barra de tareas / volumen de Windows y responde a teclas multimedia.

4. **Regla de Skip Silence (Windows & Android):**
   - **Windows (`media_kit`):** Aplica filtro ffmpeg `silencedetect=noise=-50dB:duration=0.3`. Parsea logs de mpv para ejecutar un `seek` único al primer sample de audio real (`silence_end`).
   - **Android (`just_audio`):** Utiliza el flag nativo de ExoPlayer `setSkipSilenceEnabled` reservado para podcasts/spoken-word.

5. **Providers Riverpod (`player_providers.dart`):**
   - Provider principal `syncoraPlayerControllerProvider` (ChangeNotifierProvider) que vincula el controlador con los adaptadores de controles de SO según la plataforma.
   - Selectores reactivos: `isPlayingProvider`, `currentTrackProvider`, `playerStateProvider`.

6. **Pantalla Debug Actualizada (`/debug`):**
   - `ExtractionDebugScreen` actualizada para consumir Riverpod y `SyncoraPlayerController`.
   - Incluye cola de prueba con 3 video IDs reales, controles de cola, repeat mode, shuffle, skip silence toggle e indicador de error 403.

7. **Corrección de Deuda de Seguridad (`network_security_config.xml`):**
   - Restringido `<base-config cleartextTrafficPermitted="false">` a nivel global.
   - Habilitado `cleartextTrafficPermitted="true"` únicamente para `127.0.0.1` y `localhost` (proxy interno de `just_audio`).

8. **Pruebas Automatizadas (20/20 pasando):**
   - `syncora_player_controller_test.dart`: transiciones de estado, guard 403, auto-skip, repeat mode.
   - `skip_silence_test.dart`: parseo de logs de mpv, seek exacto a `silence_end`, seek único por pista.

---

## 🛠️ Arquitectura Final y Decisiones

- **`SyncoraTrack` ≠ `MediaItem`:** Modelo propio de dominio independiente de paquetes Android-only. Los adaptadores de SO lo traducen según la plataforma.
- **Controlador como `ChangeNotifier`:** Permite testeo unitario puro y se envuelve en `ChangeNotifierProvider` vía Riverpod.
- **Separación estricta por Plataforma:** `audio_service` opera exclusivamente en Android; `smtc_windows` opera exclusivamente en Windows.
- **Sin fugas de estado:** `SyncoraAudioHandler` soporta `updateController` para actualizar la referencia cuando Riverpod recrea el provider.

---

## 🧪 Estado de Pruebas

- `flutter analyze`: **0 issues (0 errores, 0 warnings, 0 infos)**.
- `flutter test`: **20 passed, 1 skipped (benchmark de integración por diseño)**.
- `flutter build windows --debug`: **Exitoso (`syncora_player.exe`)**.
- `flutter build apk --debug`: **Exitoso (`app-debug.apk`)**.
