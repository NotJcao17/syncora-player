# Quinta ronda de correcciones (post-Fase 8)

Sesión del 2026-10-03. Plan, diagnóstico, decisiones y estado. Cada bundle cerró con
`flutter analyze` limpio, los tests de su área en verde, commit y push.

## Diagnóstico (leyendo código y la API de Deezer en vivo)

- **H-R5-1. Crossfade en skips manuales.** `_playCurrentGuarded` decidía el crossfade solo con
  "ajuste > 0, pista actual y nueva descargadas, motor sonando". No sabía si la transición venía
  del fin natural de la pista o de un botón, así que "siguiente"/"anterior"/elegir otra canción
  también cruzaban.
- **H-R5-2. "Siguiente" muerto mientras carga.** `skipToNext` sostenía `_isTransitioning` durante
  toda la extracción (2-3 s) y el segundo toque salía por el guard. La mutación de la cola es
  síncrona; lo lento es la carga, que ya se descartaba sola por `_playGeneration`. Además el isolate
  procesa en orden: tres toques eran tres extracciones en fila.
- **H-R5-3. Ícono de play durante la búsqueda/match.** Entre el `stop()` del motor y el `setUrl` el
  motor está en `idle`. El adaptador del SO ya publicaba `loading` en esa ventana
  (`isPreparingPlayback`), pero la UI no la veía.
- **H-R5-4. Portadas de descargas borradas.** `CoverCacheService` tenía un LRU de 200 entradas que
  **borraba archivos de portada** de canciones descargadas a partir de la 201 (esa carpeta no es una
  caché). Y si un archivo local no se podía decodificar, `TrackCoverImage` mostraba el hueco sin
  intentar la red.
- **H-R5-5. Portadas que fallan en grupo solo en móvil.** No reproducible desde el PC (46 portadas en
  ráfaga, todas 200, `max-age` de 150 días). Hipótesis más fuerte: conexiones HTTP reutilizadas que
  la red móvil ya cerró (el NAT corta conexiones ociosas; `HttpClient` las reusa hasta 15 s), así
  que fallan juntas todas las que salen a la vez. Las recomendaciones al pie de la playlist usaban
  `CachedNetworkImage` sin reintento.
- **H-R5-6. Deezer `/artist/{id}/top` devuelve `{"data":[],"total":0}`** para todos los artistas
  probados (2026-10-03, desde México). `/radio`, `/albums`, `/album/{id}/tracks` y
  `/search/playlist` responden bien. Dejaba vacío "Populares" en la pantalla de artista.
- **H-R5-7. Teclado trabado en hojas con campo de texto.** Con una hoja abierta, todo lo de debajo
  seguía al teclado en cada frame: el `Scaffold` del shell redimensionando su cuerpo, el `SafeArea`
  + `LayoutBuilder` del reproductor a pantalla completa, las cabeceras de playlist/álbum/artista
  (usaban `MediaQuery.paddingOf`, que cambia con el teclado) y cada asa de la cola.
- **H-R5-8. Los dos sliders de "Crear playlist con IA" eran casi el mismo eje.** `familiarity` 0 =
  "mainstream" y `popularity` 1 = "éxitos masivos".
- **H-R5-9. Biblioteca, Inicio y la barra lateral cargaban todas las canciones de cada playlist.**
  Cada portada 2x2 y cada contador abría su propio `watchTracksOrdered`: con playlists de cientos de
  canciones, cada visita a Biblioteca o Inicio traía miles de filas del isolate de la base de datos
  solo para contar o elegir 4 portadas. El corazón del mini reproductor hacía lo mismo con "Tus me
  gusta".
- **H-R5-10. La pantalla de playlist se reconstruía entera con cada cambio del reproductor.**
  Escuchaba `currentTrack`/`isPlaying` arriba del todo, creaba sus streams de Drift dentro de
  `build` y rehacía orden, filtro y listas derivadas en cada rebuild. El mapeo inicial (un
  `jsonDecode` de colaboradores por fila) corría en el hilo de la UI.
- **H-R5-11. Un rechazo del servidor al agregar una canción borraba la playlist local.** En
  "Agregar a playlist", cualquier error remoto se trataba como "la playlist ya no existe en la
  nube" y se borraba la local. Con el límite de 10 000 eso habría borrado playlists llenas; ahora
  ese error se reconoce aparte.
- **H-R5-12. Créditos con la tipografía equivocada.** La app usa Inter
  (`GoogleFonts.interTextTheme`), pero README y "Créditos" decían Plus Jakarta Sans.

## Bundles (todos implementados)

1. **Reproductor:** H-R5-1 (crossfade solo en el avance natural), H-R5-2 (el guard cubre solo la
   cola; una sola extracción de streaming en el isolate y como mucho una esperando, que se
   reemplaza por la más nueva y vuelve como `cancelled`; una carga interrumpida no muestra error),
   H-R5-3 (`SyncoraPlayerState.isPreparing` / `isLoading`; la fila activa muestra spinner y tocarla
   mientras carga no la relanza) y portada de la pista siguiente precargada en la caché de memoria.
2. **Cola:** "Mejorar cola" rápida, sin IA (`improveQueueWithRecommendations`: radio de Deezer,
   1 recomendación cada 3 canciones, entre 10 y 50, marcadas con `isSuggested`) y "Crear con IA"
   simplificada (texto + ideas de un toque + "tener en cuenta lo que estoy escuchando" + 10/25/50),
   cuyo resultado va a la cola manual. H-R5-7 con `KeyboardInsetFreeze`.
3. **Portadas:** H-R5-4 (sin LRU en las portadas de descargas, bytes validados, archivo dañado →
   red), H-R5-5 (`FileService` propio: conexiones ociosas de 4 s y un reintento ante fallo de
   conexión; recomendaciones con `TrackCoverImage`; logs `[Covers]`).
4. **Letras:** `SyncedLyricsList` compartida por móvil y escritorio. Todas las líneas se maquetan
   con la misma letra, el mismo grosor y el mismo ancho (disponible / escala) y centradas; la
   activa solo se escala al pintarse, así que los saltos de línea nunca cambian. Desplazarse a mano
   deja de seguir la canción y muestra "Sincronizar"; se vuelve a seguir al tocarlo, al tocar una
   línea o al volver cerca de la línea que suena.
5. **Gestos (patrón de Spotify):** deslizar para encolar desde cualquier punto de la fila; 2,5× el
   umbral de toque y 2,5× más horizontal que vertical para aceptar; nunca empieza con la lista en
   movimiento; vibración y fondo avivado al cruzar el 30 %; resistencia pasado el umbral y tope en
   la mitad del ancho; al soltar se encola y la fila vuelve.
6. **Rendimiento:** H-R5-9 (`watchPlaylistSummaries`: una consulta con funciones de ventana que
   devuelve conteo y 4 portadas por playlist), H-R5-10 (streams cacheados, filas y botón de cabecera
   con sus propios `Consumer`, listas derivadas memorizadas, mapeo en un isolate desde 300
   canciones), el toque que frena la lista no reproduce, y barra de desplazamiento arrastrable en
   playlists de más de 40 canciones en móvil.
7. **Pulido de UI:** globos de ayuda (tooltips) con la superficie de la app, toast en azul pizarra
   con acción lavanda, "Búsquedas recientes" sin cortarse, "Eliminar descarga" en Descargas.
8. **Catálogo:** "Esto es {artista}" (`getArtistEssentials`: sus 14 lanzamientos con más seguidores
   sin recopilaciones, solo canciones donde es el artista principal, una versión por título, orden
   por `rank`; si `/top` responde, sus canciones van primero) y respaldo de "Populares" para
   H-R5-6. Entradas del artista rediseñadas con su foto e insignia. Filtro "Playlists" en el
   buscador (fuera de "Todo"; editoriales de Deezer primero) y sección "Para cada momento" en
   Inicio.
9. **Límites:** `AppLimits` (nombre 100, descripción 300, 10 000 canciones). Campos con tope y
   contador que aparece cerca del límite; DAO y repositorio recortan textos de origen externo;
   comprobación antes de escribir en "Agregar a playlist", "Agregar todas", agregar desde el
   buscador interno y las recomendaciones, "Me gusta", importación (primeras 10 000), copia de
   colecciones y "Modificar con IA → agregar". Migración 21 como respaldo en Supabase. H-R5-11.
10. **IA:** un solo control "Éxitos / Mezcla / Por descubrir" (manda solo `familiarity`; la Edge
    Function no cambia).
11. **Android Auto:** `getChildren`/`playFromMediaId`/`search`/`playFromSearch` en
    `SyncoraAudioHandler` (Tus me gusta, escuchado recientemente, tus playlists, descargas;
    búsqueda por voz con Deezer) y `automotive_app_desc.xml` en el manifiesto.
12. **README** reescrito y crédito de tipografía corregido (H-R5-12).

## Decisiones que no conviene revertir

- **El crossfade es solo para el avance natural.** Cualquier acción del usuario cambia en seco.
- **"Siguiente" nunca espera a la carga.** Solo la mutación de la cola está protegida; una carga
  vieja se descarta por generación y nunca muestra error. Dos toques en "Reintentar" durante una
  cascada de auto-skip cuentan como intervención del usuario (el contador vuelve a 0).
- **Lo que pide el usuario a la IA va a la cola manual**; "Mejorar cola" es la que intercala.
- **Las portadas de descargas no son caché**: no se borran por cantidad.
- **Conteos y portadas de playlists salen de `playlistSummariesProvider`**, nunca de un
  `watchTracksOrdered` por tarjeta.
- **Los streams de Drift no se crean dentro de `build`** (se re-suscriben en cada rebuild).
- **Los límites de texto del servidor son más holgados que los de la app** (200 / 1000) para no
  romper filas existentes; el de canciones es el mismo (10 000) y su error lleva el texto
  `playlist_track_limit`, que la app reconoce.

## Respuestas a las preguntas de la sesión

- **Importación masiva → Supabase:** por bloques de 10 canciones (`ImportManager._insertChunk`), un
  `INSERT` con las 10 filas a la vez y un reintento; cada bloque sube antes de insertarse en local.
  Si la nube rechaza un bloque, la importación se pausa.
- **¿Se cierra del todo la app?** Al quitarla de recientes, `onTaskRemoved` detiene la reproducción
  y el servicio, pero Android suele conservar el proceso en caché un rato; por eso `flutter run` ya
  no pierde la conexión. Lo más probable es que antes muriera porque el servicio en primer plano se
  soltaba al pausar; desde la ronda 3 bis (`androidStopForegroundOnPause: false`) el proceso
  sobrevive mejor.
- **Estadísticas sin cuenta:** salen del `listening_history` local, que no se poda (crece ~2 MB al
  año, aceptado en 7.I). Solo hay vistas Semanal y Mensual; Anual/Wrapped y "Desde el inicio" son
  exclusivas de cuenta porque dependen del agregado mensual de Supabase.
- **"Skipped 33 frames" + "Lost connection to device":** el primero es normal en `flutter run`
  (modo debug, varias veces más lento y sin AOT). El segundo es el proceso muriendo o la conexión
  ADB cayéndose; en debug el consumo de memoria es mucho mayor y Android mata antes a la app. Si se
  repite en `--release` o `--profile`, hace falta el `adb logcat` de ese momento (buscar
  `lowmemorykiller`, `Fatal signal` o `ANR`).

## Pendiente

- Aplicar la migración `20250001000021_content_limits.sql` en Supabase.
- Pruebas en dispositivo (Android y Windows) de todo lo de arriba, en especial: portadas en móvil
  (si vuelven a fallar, mandar las líneas `[Covers]` de la consola), Android Auto y la sensación de
  los gestos.
- Medir con DevTools en `--profile` si todavía hay tirones al abrir playlists muy grandes.
