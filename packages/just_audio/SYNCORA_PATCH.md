# just_audio 0.10.6 con un parche de Syncora

Copia de `just_audio` 0.10.6 de pub.dev (sin `example/` ni `test/`), usada desde
`pubspec.yaml` con `dependency_overrides`. Licencia original en `LICENSE`.

## El único cambio

`android/src/main/java/com/ryanheise/just_audio/AudioPlayer.java`, en
`ensurePlayerInitialized()`:

```java
.setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, true)
```

## Por qué (ronda 10, 2026-10-22)

YouTube solo entrega al cliente ANDROID el itag 18: un MP4 de **video 360p** con
audio (Pitfall #39). ExoPlayer decodificaba la pista de video aunque no hubiera
pantalla (`c2.mtk.avc.decoder` en logcat), con la app horas en segundo plano.
Con el video desactivado ExoPlayer solo selecciona y decodifica el audio.

## Al actualizar just_audio

Con el override, `flutter pub upgrade` y `flutter pub outdated` no tocan esta copia.

1. En `pubspec.yaml`, subir `just_audio:` en `dependencies` a la versión nueva y quitar
   temporalmente el bloque `just_audio:` de `dependency_overrides`; `flutter pub get` la baja a
   `%LOCALAPPDATA%\Pub\Cache\hosted\pub.dev\just_audio-X.Y.Z`.
2. Borrar el contenido de esta carpeta (menos este archivo) y copiar ahí la versión nueva sin
   `example/` ni `test/`.
3. Volver a agregar la línea de arriba en `ensurePlayerInitialized()` y reponer el override.
4. `flutter pub get`, `flutter analyze`, `flutter test`
   (`test/features/player/audio_engine/just_audio_engine_test.dart` cubre cómo llegan los errores,
   Pitfall #38).
5. Compilar el APK de release, instalarlo con `adb install -r` y, con una canción sonando por
   streaming, comprobar en logcat que solo aparece `c2.*.aac.decoder` y no `c2.*.avc.decoder`:
   ```bash
   adb logcat | findstr decoder
   ```
6. Actualizar la versión en el título de este archivo.
