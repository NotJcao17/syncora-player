# Octava ronda de correcciones (2026-10-11)

Primera ronda tras publicar la 1.0.2. Cada bundle cerró con `flutter analyze` limpio, la suite completa
en verde (835 tests al final), commit y push. Sin migraciones ni cambios en Supabase.

## Hallazgos verificados

- **H-R8-1. Se saltaba una canción de cada dos (solo Android).** Al terminar una pista, `just_audio`
  deja `playing = true` con el estado `completed`. Para cargar la siguiente, el controlador hace
  `stop()`, que publica `playing = false` con el estado todavía en `completed`, y
  `JustAudioEngine._onPlayerState` volvía a avisar "fin de pista". Desde la ronda 5 (H-R5-2) el guard
  de "siguiente" se suelta antes de cargar, así que ese segundo aviso avanzaba otra vez. Venía desde
  la 1.0.0. Arreglo en dos capas: el motor avisa solo al **entrar** en `completed`, y `_onComplete`
  ignora cualquier fin mientras se está cargando una pista (`_preparingPlaybackGeneration`).
  Reproducido en un test con un motor falso que repite el aviso en `stop()`, como el real.
- **H-R8-2. Tras pausar y elegir otra canción, se quedaba trabada al final** (lo que se vio en
  Windows). `_lastPauseWasUserInitiated` solo se limpiaba en `play()`. Pausar y luego tocar otra
  canción o "siguiente" la reproducía, pero su fin se tomaba por la completion espuria de un motor en
  pausa y se ignoraba. Ahora se limpia en cuanto arranca cualquier pista (`_playCurrentInternal`).
  Antes se descartó con el motor real de `media_kit` que la posición restaurada fuera la causa (fin
  de archivo correcto con y sin `start`).
- **H-R8-3. No había precarga de la siguiente canción.** Solo se precalentaba la pista restaurada al
  abrir la app. Ahora, en los últimos 30 s de la pista, se extrae la siguiente (búsqueda + URL). Va
  por el mismo carril de streaming, así que un "siguiente" del usuario nunca queda detrás de más de
  una precarga. La reproducción reutiliza esa extracción aunque siga en curso. Si falló o tiene más de
  30 min, se extrae como siempre.
- **H-R8-4. "Sign in to confirm you're not a bot".** Desde la PC, los masters de "Von dutch", "23",
  "2002" y "Skyfall" se extraen al primer intento: en el teléfono fue la red móvil (IP marcada), y
  pausar es lo correcto (Pitfall #14). Cambios: el aviso ya no muestra el error técnico
  (`friendlyPauseMessage`), y si un candidato pide verificar se prueba **un** video más antes de
  pausar (por si es de ese video), sin el reintento de 2 s sobre el mismo video.
- **H-R8-5. Versión equivocada al reproducir.** Tres causas, con candidatos reales capturados en
  `test/fixtures/yt_versions/`:
  - "Skyfall": YouTube Music devuelve primero "Skyfall (Originally **Perfomed** By Adele)", un karaoke
    con errata que el filtro "originally performed" no atrapaba. Como el título nombra a Adele, contaba
    como del artista.
  - "23" y "2002": el **motor de fábrica** (youtubei.js 17.2.0) leía el título numérico como duración
    en YouTube Music (23 s, 2002 s). El matcher descartaba el master por duración absurda y entraba
    otro autor con duración parecida: "SALMOS 23" de un coro (la canción de iglesia) o el cover de
    Grace Watson.
  - Arreglos: más marcadores de cover (errata incluida). En YouTube Music, otro autor conocido es otro
    intérprete y se descarta. En títulos de una palabra, sin el artista confirmado no vale un título
    con palabras de más. Una duración igual a un número del título se toma como desconocida. Y el
    motor de fábrica pasa a youtubei.js 18.1.0 (build 202610112130), que lee bien la duración.
  - Medido sobre 40 canciones reales de la playlist "2026": el matcher nuevo elige exactamente lo
    mismo que el anterior en las 40. Solo cambia cuando el master falla o es un impostor.
- **H-R8-6. La importación elegía la versión con invitado o de otra grabación.**
  - "Ojos Marrones": el álbum "Eva" trae la de Lasso y la de "(Con Sebastián Yatra)".
    `normalizeTitle` quita el invitado, así que empataban y desempataba la popularidad.
  - "I'm Not The Only One": "In The Lonely Hour (10th Anniversary Edition)" se normaliza igual que el
    álbum del archivo y su pista sin sufijo es la de Alicia Keys (220 s contra 239 s). 19 s de
    diferencia apenas restaban.
  - Arreglos: un invitado que la fila no trae resta (y al revés, si la fila lo pide y el candidato no
    lo trae). Más de 5 s de diferencia es otra grabación y ya no gana por el álbum.
  - Medido contra Deezer real con 74 filas de la playlist "2026": solo cambian esas dos, a la
    correcta. Las playlists ya importadas no se corrigen solas.
- **H-R8-7. Toques fantasma al bajar el reproductor.** Una ruta que se cierra ignora los toques
  durante su animación (`ModalRoute`), así que caían en la pantalla de abajo: el siguiente toque ponía
  una canción de la playlist. `PlayerDismissShield` bloquea el shell mientras baja el reproductor
  (+150 ms). El test falla sin el escudo.
- **H-R8-8. El gesto de "atrás" de Android movía la lista.** El `RawScrollbar(interactive: true)`
  agarraba el pulgar (pegado al borde derecho) en cuanto se tocaba, y el temblor vertical del gesto
  lo arrastraba. `FastScrollbar` propio: el pulgar sigue pegado al borde, pero solo se arrastra con un
  movimiento claramente vertical (el doble que el horizontal) y se rinde si empieza horizontal.
- **H-R8-9. El orden de la playlist no se guardaba.** Vivía en el estado de la pantalla. Ahora se
  guarda por playlist y dispositivo (`playlist.sort.<id>`), y hay "Agregadas recientemente" (el orden
  original al revés: en una importación todas comparten fecha) y "Artista". En PC, "#" alterna con
  agregadas recientemente y la cabecera tiene TÍTULO · ARTISTA.
- **H-R8-10. Historial de reproducción ilegible.** La escucha en curso se vuelca cada 15 s, y cada
  volcado reemitía la lista: se volvían a pedir las 100 canciones a Deezer (el caché de `DeezerApi`
  guarda 30) con el esqueleto en pantalla. Ahora el stream solo emite si cambia lo visible, cada
  canción se pide una vez por sesión (`historyTrackProvider`) y al llegar una escucha nueva no vuelve
  el esqueleto.
- **H-R8-11. Pantalla de bloqueo.** Tocar el reproductor de la notificación o de la pantalla de
  bloqueo abre el reproductor a pantalla completa (`AudioService.notificationClicked`, solo Android).
- **Página de inicio de sesión en Windows** con los colores, la tipografía y el logo de la app
  (`desktop_auth_pages.dart`). Además, el texto de error que llega por la URL ahora se escapa.

## Decisiones que no conviene revertir

- **Un fin de pista solo cuenta si no se está cargando otra.** No volver a sostener el guard de
  "siguiente" durante la carga (H-R5-2); la defensa está en `_onComplete` y en el motor.
- **Arrancar una pista limpia la pausa del usuario.** Si no, su final se ignora.
- **La precarga va por el carril de streaming y solo en los últimos 30 s.** Antes de eso, una
  extracción especulativa haría esperar a un "siguiente" real (el isolate atiende de una en una).
- **En YouTube Music, otro autor conocido es otro intérprete**: descartado, no solo "sin confirmar".
- **Una duración igual a un número del título no es dato.** Protege también si vuelve un motor viejo.
- **Importación: misma grabación = misma duración (±5 s).** El álbum coincidente no gana si la
  duración dice que es otra grabación.
- **El escudo del reproductor siempre envuelve el shell** (mismo `AbsorbPointer`, solo cambia el
  valor; Pitfall #33).

## No se cambió

- **Login de Google en Android** (la pestaña del navegador queda abierta): decisión del usuario, se
  deja así.
- **"Esto es {artista}"** ya tenía el botón "+" para guardar una copia.

## Pruebas en dispositivo pendientes

Ver la lista numerada del cierre de la sesión; en resumen: dejar correr varias canciones seguidas en
Android (streaming y descargadas), pausar y elegir otra canción, el cambio de pista tras 30 s, bajar
el reproductor y tocar enseguida, el gesto de atrás sobre la barra de una playlist larga, la
notificación, el orden de playlist tras reiniciar, el historial con una canción sonando, "23",
"2002" y "Skyfall", reimportar el CSV de "2026", y el login en Windows.

## Segunda tanda (tras la primera prueba en dispositivo)

Resultado de la prueba: todo bien salvo Skyfall y el historial; además apareció el orden perdido al
volver a iniciar sesión.

- **Skyfall seguía sonando como cover.** Con el motor nuevo ganaba "Skyfall (From "Skyfall")", que
  YouTube Music devuelve sin autor y es de "Release - Topic" (un sello de recopilaciones). Un
  resultado sin autor se llevaba el bono de fuente oficial. El master de Adele no aparece en esa
  búsqueda y el video oficial (AdeleVEVO) está en la de videos, que no llegaba a correr. Arreglos:
  sin autor no hay bono; el canal con el nombre **exacto** del artista suma `officialChannelBonus`
  (60), porque los videos de letra a 1 s de la duración le ganaban al oficial a 4 s; y si YouTube
  Music no trae ningún candidato del artista confirmado, se hace también la búsqueda de videos antes
  de elegir. Sobre las 40 canciones medidas cambia solo "Take a Hint" (de "Release - Topic" a un
  video de letra de la misma canción). Con el motor real: Skyfall → AdeleVEVO; 23, 2002, Von dutch y
  Midnight City siguen igual.
- **H-R8-10 (historial), segunda versión.** El historial mostraba la mitad como "Desconocida /
  Artista Desconocido". Deezer responde 200 con `{"error": ...}` cuando se agota la cuota (pedir 100
  canciones de golpe la agota), y `DeezerApi.getTrack` lo convertía en una pista "Desconocida" y la
  cacheaba. Ahora `getTrack` lanza ante esa respuesta. Además, el historial se arma **una vez al
  entrar** (sin escuchar la tabla en vivo, propuesta del usuario): título, artista y portada salen de
  las playlists locales (`PlaylistDao.findTracksByTrackIds`) y a Deezer solo se le pide lo que falte,
  de una en una. Las estadísticas también guardaban esas pistas "Desconocida" en su caché persistente;
  ahora esas entradas se vuelven a pedir.
- **H-R8-12. Tras cerrar e iniciar sesión, la playlist salía en otro orden** (igual en PC y móvil).
  Verificado con la base local de la PC: la playlist "2026" tenía las últimas ~138 canciones
  revueltas al principio y el resto en orden. Solo la importación mandaba `order_index` a la nube;
  "Agregar a playlist", "Me gusta", guardar una colección y subir una playlist local quedaban con el
  `DEFAULT 0` de la columna, y al bajar la playlist esas filas salían primero, desempatadas por un
  uuid aleatorio. En Syncora no hay reordenar a mano: el orden es el de inserción. Arreglos:
  - `SupabasePlaylistRepository.addTrack(s)ToPlaylist` numera tras la última de la nube toda fila
    que no traiga `order_index`.
  - **Migración 25** (`20250001000025_playlist_track_order_repair.sql`): renumera solo las playlists
    con `order_index` repetidos, por `added_at`, luego `order_index`, luego `ctid`. Los dispositivos
    no reordenan su copia local solos (el sync no reordena); se ve al volver a bajar la playlist
    (cerrar e iniciar sesión). Las colecciones guardadas en un solo INSERT sin `order_index`
    dependen de `ctid`, que normalmente conserva el orden de envío.

## Tercera tanda

- **Migración 25 aplicada** (2026-10-11, con permiso del usuario). Antes se midió: 24 playlists con
  `order_index` repetidos (2714 filas). La simulación sobre "2026" pasó de 196 tramos revueltos a 72
  (los cortes que quedan son títulos que Deezer escribe distinto o repetidos en el CSV). Después de
  aplicarla, 0 playlists con repetidos.
- **"Die Young" de Kesha sonaba de otro artista.** En YouTube Music el master viene con autor
  "Ke$ha"; `norm` convertía el `$` en espacio ("ke ha" ≠ "kesha"), así que el master contaba como de
  otro intérprete y podía ganar un cover ("Betty .C.", 214 s). Ahora `$` cuenta como "s" (Ke$ha,
  A$AP Rocky). Con el motor real elige el master `Bgy3NB4c4ms`.
- **H-R8-13. GPU en Windows (4-10 % con la app quieta sonando).** `media_kit` emite el estado ~15
  veces por segundo (medido: 14.5/s) y cada emisión notificaba a la UI: barra de progreso y tiempos
  repintados a 15 fps. Ahora los ticks que solo cambian la posición se publican como mucho cada
  250 ms; play, pausa, carga, duración y saltos (seek) siguen al instante, y la lógica interna
  (escuchas, crossfade, precarga) sigue viendo cada tick. El 20-30 % al desplazar una playlist es lo
  esperable en Flutter con GPU integrada (se dibuja un frame completo por cada refresco de pantalla
  mientras la lista se mueve); no se cambió.
