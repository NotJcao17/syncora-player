# Décima ronda de correcciones (2026-10-21)

Segunda ronda tras publicar la 1.1.0. `flutter analyze` limpio y la suite completa en verde (874
tests). Sin migraciones ni cambios en Supabase. **Leer antes de tocar el manejo de errores del motor
de audio, los saltos automáticos, `stop()` del controlador, lo que se publica al SO
(`SyncoraAudioHandler`, `WindowsMediaControls`), la elección de formato del motor de extracción o
"Escuchado recientemente".**

**Estado: en `master`, sin publicar.** Faltan las pruebas en dispositivo de abajo.

## Hallazgos verificados

- **H-R10-1. Pausar ~10 min y darle play empezaba la canción desde 0 (Android).** Reproducido en el
  teléfono con logcat: a los 10:00 exactos de pausa, SystemUI marca la sesión como vencida
  (`MediaDataManager ... timedOut: true`) y le manda **stop** a la app (`callingPackage:
  com.android.systemui ... MediaSessionRecord:stop`). La notificación pasa a ser el reproductor de
  "reanudar" (sin barra). Es normal en Android; lo que estaba mal es que `stop()` del controlador
  olvidaba la posición y el play siguiente recargaba desde 0. Ahora `stop()` guarda el segundo
  (`_restoredPositionSeconds`) y el play lo retoma (también al cerrar la app desde recientes).
- **H-R10-2. Los errores de ExoPlayer no llegaban al controlador.** En just_audio 0.10 ya no llegan
  como error del stream (`playbackEventStream.onError` nunca se dispara) sino como un evento con
  `errorCode` y el estado en `idle`. `JustAudioEngine` lo tomaba por un `idle` cualquiera: en pausa,
  play recargaba desde 0; sonando, el reproductor se quedaba quieto. Ahora `idle` + `errorCode` es
  `error`. Test con una plataforma de just_audio falsa que emite el error como el `AudioPlayer.java`
  real. Consecuencia: en Android un error del motor ahora sí dispara la política de saltos (abajo).
- **H-R10-3. YouTube ya solo da el itag 18 al cliente ANDROID.** Medido el 2026-10-21: de 23
  formatos, 1 trae URL; es MP4 de **video 360p** con audio AAC de baja calidad. Los de solo audio
  de ANDROID_VR (itag 140) responden 206 al primer MB y **403 a todo lo demás** (exigen PoToken, que
  no podemos generar: Pitfall #18). Así que todo suena desde el itag 18, y en Android se decodifica
  video H.264 sin pantalla (`c2.mtk.avc.decoder` en el log). Sin arreglo del lado del motor.
- **H-R10-4. "Crazy in Love" y "End of Beginning" no sonaban nunca.** Su itag 18 es una muestra de
  ~4 kbps (120 KB para 4 min). `glue.js` rechaza un formato con video de menos de 32 kbps ("formato
  de muestra"), y el isolate pasa al **siguiente video candidato** (no al siguiente cliente: ANDROID_VR
  daría una URL que muere al primer MB). Con el motor real: Crazy in Love → video oficial
  `ViwtNLUqkMY`, End of Beginning → `OjzP82N4DxY`.
- **H-R10-5. "Julia" de LAGOS sonaba en la versión sin Lasso.** Dos subidas de YouTube Music a ≤3 s
  de la duración de Deezer recibían el mismo +100 y decidía el orden de YouTube por 1 punto. Ahora
  dentro de esa franja resta un punto por segundo. Medido sobre 360 canciones de "2026": solo
  cambian Julia (ahora "Julia · LAGOS · Lasso") y "September" (ahora el lanzamiento original de 1978
  en vez de una recopilación de 2018, 216 s exactos). **"By the End of the Night"**: el video elegido
  es la versión del álbum *Higher Than Heaven*, misma duración que el sencillo (188.7 s); no se
  encontró nada que corregir. La importación del CSV eligió bien las cuatro (mismo ISRC).
- **H-R10-6. Arreglo de "not a bot" (ronda 9) con un hueco.** El isolate clasificaba el video con el
  error del **último** cliente. WEB contesta hoy siempre "UNPLAYABLE: Video unavailable", así que si
  ANDROID pedía verificar, ese aviso se perdía: la canción se daba por no encontrada (salto) y la
  sesión nunca se renovaba. Ahora, si cualquier cliente reporta el bloqueo, ese error manda
  (`decisiveClientError`). El resto del diseño de la ronda 9 está bien.
- **H-R10-7. Batería en segundo plano (44 % en 4 h).** Encontrado en el teléfono:
  - El adaptador de `audio_service` republicaba **cada ~400 ms** la sesión entera: pista, la cola
    completa (cientos de canciones serializadas por el canal de plataforma) y el estado. Android
    calcula la posición solo; ahora se publica solo lo que cambia (pista, cola, play/pausa, carga,
    controles o un salto de posición). En Windows (SMTC) igual con el estado y los metadatos.
  - Todo el audio pasaba por el proxy HTTP en Dart de just_audio (por los headers). Ahora ExoPlayer
    manda el mismo User-Agent de forma nativa (`useProxyForRequestHeaders: false`).
  - ExoPlayer decodificaba la pista de video del itag 18 (H-R10-3). Resuelto en la segunda tanda
    con una copia parcheada de just_audio (abajo).
- **H-R10-8. Borde gris en el lado derecho al entrar a una playlist larga o al girar (móvil).** Era el
  `ErrorWidget` de release. `FastScrollbar` devolvía `child` a secas cuando estaba desactivada y lo
  envolvía al activarse (las canciones llegan después, o cambia el modo al girar): la lista se
  recreaba, por un frame el controlador tenía dos posiciones y `controller.position` lanzaba. Misma
  familia que el Pitfall #33. Ahora la estructura es siempre la misma.
- **H-R10-9. El aviso "Playlist actualizada" quedaba a media pantalla.** `AppToast` tomaba el alto
  del teclado al mostrarse; al guardar, el teclado se cerraba justo después. Ahora el alto del
  teclado se lee en cada frame y el aviso baja a su sitio. Sin teclado, el margen es el de siempre.
- **H-R10-10. PC: no se podía arrastrar la barra al reabrir la app hasta pulsar play.** Sin nada
  cargado el motor ignoraba el salto. Ahora `seek()` sin nada cargado fija el segundo desde el que
  arranca la pista.
- **H-R10-11. PC/Inicio: "Playlist eliminada" y una sola playlist en "Escuchado recientemente".**
  `recentlyPlayedProvider` se calculaba una vez y guardaba los ids locales; si eso pasaba con la
  biblioteca a medio sincronizar, se quedaba corto y con ids que el sync después reemplazaba. Ahora
  escucha Drift (playlists y álbumes).

## Cambios de comportamiento (pedidos)

- **Nunca dos saltos automáticos seguidos.** Antes el guard de cascada cortaba al tercer fallo. Ahora
  una canción que no se puede reproducir (sin coincidencia, fallo de carga con otra en cola, error del
  motor al empezar) se salta una vez; si la siguiente tampoco, pausa con aviso ("Siguiente" lo
  vuelve a intentar). El contador **no** se repone con una extracción exitosa (una URL que el motor no
  abre también "se extrae bien" y así se saltaba en bucle, Pitfall #14), sino cuando algo suena ≥3 s
  o el usuario interviene.
- **Corte a mitad de canción:** se recarga la misma en el mismo segundo, una vez; si vuelve a fallar,
  pausa. Antes se saltaba a la siguiente.
- **Configuración → Reproducción → "No se pudieron reproducir":** registro del dispositivo con las
  últimas 50 canciones que no sonaron, motivo y hora (`UnplayableTrackLog`).
- **Wrapped en minutos** ("12,345 · MINUTOS ESCUCHADOS"), como Spotify. Estadísticas sigue en h/min.
- **Orden alfabético** sin acentos ni signos iniciales ("Él", "¿Qué…?" ya no van al final).

## Decisiones que no conviene revertir

- `stop()` del controlador recuerda el segundo: el sistema lo manda solo tras 10 min de pausa.
- `JustAudioEngine` trata `idle` + `errorCode` como error; un error durante la carga lo atiende el
  camino de carga, no `_onEngineState`.
- El presupuesto de saltos se repone con reproducción real, nunca con extracción exitosa.
- Al SO solo se le publica lo que cambia; la posición la extrapola Android.
- `FastScrollbar` (y cualquier widget que envuelva una lista con controlador) no cambia de estructura
  al activarse.
- Un itag 18 de menos de 32 kbps es una muestra: siguiente candidato, no siguiente cliente.

## Segunda tanda (tras la primera prueba en dispositivo)

- **H-R10-12. Tocar una búsqueda reciente solo escribía el texto.** Al volver a la pestaña Buscar la
  pantalla se recrea con el campo vacío, pero `searchProvider` conserva la última consulta; tocar esa
  misma búsqueda llamaba a `setQuery`, que no hace nada si la consulta no cambió, y sin cambio de
  estado la pantalla ni se redibujaba. Ahora el chip usa `searchNow`, que busca siempre.
- **H-R10-13. "End of Beginning" sonaba instrumental.** Tras descartar la muestra del master, el
  siguiente candidato de YouTube Music era "End of Beginning (By Djo)", **sin autor**: una pista de
  ZZang KARAOKE (canal "Release - Topic"). El título nombraba a Djo y eso lo daba por "del artista".
  Ahora en YouTube Music solo el autor confirma al artista, y un resultado sin autor con "by
  \<artista\>" en el título se descarta como karaoke. Medido sobre 360 canciones de "2026": el primer
  candidato elegido no cambia en ninguna; solo salen de los respaldos 2.º/3.º karaokes del mismo
  tipo (Ariana Grande, Avicii, Bruno Mars, Don Omar…). Con el motor real: End of Beginning →
  `xy3AcmW0lrQ`, "Djo - End Of Beginning (Official Audio)" del canal Djo Music.
- **H-R10-14. Sin decodificar video en Android.** `packages/just_audio/` es una copia de just_audio
  0.10.6 con una línea más (`setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, true)`), usada con
  `dependency_overrides`. Verificado en el teléfono: al sonar por streaming solo aparece
  `c2.android.aac.decoder`; antes también `c2.mtk.avc.decoder`. Cómo actualizar just_audio sin perder
  el parche: `packages/just_audio/SYNCORA_PATCH.md`.
- El OTA siguió funcionando: el push de la primera tanda publicó el motor `202610220518` (prueba
  obligatoria en QuickJS en verde, firmado en `engine-channel`).

## Pruebas en dispositivo pendientes

Ver la lista del cierre de la sesión.
