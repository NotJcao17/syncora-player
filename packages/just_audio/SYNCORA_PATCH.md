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

1. Copiar la versión nueva de `%LOCALAPPDATA%\Pub\Cache\hosted\pub.dev\just_audio-X.Y.Z`
   (sin `example/` ni `test/`) sobre esta carpeta.
2. Volver a agregar la línea de arriba.
3. Comprobar en el teléfono que no aparece `c2.*.avc.decoder` en logcat al sonar
   una canción por streaming.
