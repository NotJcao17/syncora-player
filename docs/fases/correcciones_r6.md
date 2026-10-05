# Sexta ronda de correcciones (2026-10-04)

Bugs reportados tras la ronda 5, importación de CSV de TuneMyMusic y limpieza de código muerto.

## Causas encontradas

- **H-R6-1 — El shell entero se reconstruía al abrir cualquier menú, diálogo u hoja.**
  `KeyboardInsetFreeze` (ronda 5, H-R5-7) devolvía `child` tal cual cuando su ruta estaba arriba y
  `MediaQuery(child: child)` cuando no. Abrir una ruta encima cambiaba la estructura del árbol, y
  Flutter desmontaba y volvía a crear todo lo que cuelga de él (el shell, el reproductor a pantalla
  completa, el contenido de las hojas). Síntoma visible: en PC el menú del avatar ("Mi cuenta" /
  "Cerrar sesión") aparecía en la esquina superior izquierda (su botón ya no existía) y elegir una
  opción no hacía nada (`PopupMenuButton` descarta la selección si su estado ya no está montado).
  Ahora siempre devuelve un `MediaQuery`; solo cambian los datos.
- **H-R6-2 — El menú de clic derecho solo se cerraba con clics en el área central.** `showMenu` y
  los `PopupMenuButton` del contenido usaban el `Navigator` del shell, cuya barrera cubre solo esa
  zona. Ahora van al navegador raíz (`useRootNavigator: true`, y el overlay raíz para la posición).
- **H-R6-3 — Etiqueta "Nombre de la playlist" cortada.** La etiqueta flotante del primer campo sube
  por encima de su borde y el `SingleChildScrollView` del diálogo la recortaba. Margen superior.
- **H-R6-4 — Foto de perfil que desaparece en el móvil.** Dos causas posibles:
  1. `profileProvider` devolvía `null` toda la sesión si la consulta al arrancar fallaba (sin red o
     con la sesión refrescándose), y el avatar caía al DiceBear. Ahora el último perfil leído se
     guarda por usuario en `shared_preferences` y se usa si la consulta falla.
  2. **Probable causa real, sin verificar contra la base de datos:** las imágenes subidas entre el
     2026-09-29 y el 2026-10-01 21:04 (antes del Worker) se guardaron con URLs de `r2.dev`, que
     después se desactivó. El objeto sigue en R2 (la limpieza compara por ruta, no por dominio),
     pero la URL ya no responde: el PC la muestra desde su caché y el móvil, sin caché, cae al
     DiceBear. Ver "Reparar URLs de r2.dev" abajo.

## Segunda tanda (pruebas en dispositivo)

- **H-R6-5 — "Syncora Player no responde" al cambiar la foto en Android.** `am_anr` en el logcat:
  hilo principal bloqueado >5 s unos segundos después de volver del selector. La foto se
  decodificaba entera con el paquete `image` (12 MP ≈ 50 MB por copia, varias copias). Aunque fuera
  en `compute`, los isolates comparten el recolector de basura con el principal, y desde Flutter
  3.29 el isolate principal corre en el hilo de la plataforma de Android, el que recibe los toques;
  con el teléfono corto de memoria las pausas daban el ANR. Ahora decodifica el códec nativo del
  motor, ya reducido al tamaño final (`instantiateImageCodecWithSize`), y Dart solo codifica el JPEG
  pequeño. Verificado en test con el motor real que respeta la orientación EXIF. `processImage`
  queda de respaldo para formatos que el motor no lea. El selector ya no pide los bytes por el
  canal (`withData` solo en web).
- **H-R6-10 — La causa real del ANR de H-R6-5 (tercera tanda).** El arreglo de arriba no lo
  resolvió. El volcado del ANR (`adb shell dumpsys dropbox --print data_app_anr`), simbolizado con
  la `libapp.so` de la build (`llvm-symbolizer` del NDK; la BuildId coincide y conserva los
  símbolos), mostró el hilo principal **ejecutando** Dart, no en el recolector de basura:
  `_uploadPhoto` → `AppToast.show` → `GoRouterState.of` → `ModalRoute.of`, en bucle.
  `GoRouterState.of` (go_router 17.5) entra en un bucle infinito desde una hoja abierta en el
  navegador de un `ShellRoute`: sube al `Navigator`, la página del shell no tiene estado asociado y
  `Navigator.maybeOf` devuelve el mismo navegador. La subida y el guardado ya habían terminado, por
  eso la foto sí cambiaba. `AppToast` usa ahora `GoRouter.maybeOf(context)?.state`; test de
  regresión en `test/core/widgets/app_toast_test.dart` (con el código anterior se cuelga). La
  decodificación nativa de H-R6-5 se queda: no era la causa, pero baja mucho la memoria. **No usar
  `GoRouterState.of` fuera del `builder` de una ruta.**
- **H-R6-6 — Misma trampa de H-R6-1 en `_KeyboardInset`** (`app_bottom_sheet.dart`): alternaba
  entre `KeyboardInsetFreeze` y `Padding`, así que el contenido de una hoja se recreaba cada vez que
  algo se abría encima. Ahora la estructura es fija.
- **H-R6-7 — Hojas pegadas a la cámara y la hora.** Las hojas abiertas desde pantallas del shell
  viven en el navegador del shell (encima del mini reproductor), pero su alto máximo es un % de la
  pantalla completa: las altas llegaban hasta la barra de estado. `useSafeArea: true` en todas las
  `showModalBottomSheet` (ya lo tenía la de Búsqueda desde la ronda 3 bis).
- **H-R6-8 — Payphone importado como otra grabación.** Verificado contra Deezer: la búsqueda
  "Maroon 5 Payphone" solo devuelve el de la recopilación "Sing Along Bangers" (ISRC
  `USUM71203844`, 3:42, sin Wiz Khalifa); el del CSV (`USUM71203347`) es el de *Overexposed* (3:51,
  con Wiz Khalifa), que no sale en la búsqueda pero sí en `/artist/1188/top`. Cuando el resultado no
  coincide con el álbum del archivo y hay ISRC, se compara la grabación por duración (±2 s); si es
  otra, se busca la del ISRC en el top del artista y, si no está, se usa la que da el ISRC.
- **H-R6-9 — Onda del toque congelada al volver de "Descubrir".** Las rutas son
  `NoTransitionPage`: Inicio queda tapado en el mismo frame y Flutter congela sus animaciones
  (`TickerMode`), así que la onda terminaba al regresar. Las tarjetas de acceso rápido usan ahora un
  resaltado sin animación.
- **Portadas de Descubrir en baja resolución:** no era a propósito; usaban los 250 px que guardan
  los modelos estirados a ~340 dp. Ahora piden 500 o 1000 px según la densidad (una sola tarjeta
  visible a la vez; 1000 px es la misma URL que el reproductor a pantalla completa).

## Importación de CSV

TuneMyMusic exporta igual para Spotify, Amazon Music, Apple Music y YouTube Music: `Track name`,
`Artist name`, `Album`, `Playlist name`, `Type`, `ISRC`, `<Servicio> - id`. Lo que fallaba o faltaba:

- **BOM de UTF-8** pegado al primer encabezado: "Track name" no se reconocía y **todas las filas se
  importaban como "Desconocida"**. Se quita al parsear.
- **Decodificación:** con `file.bytes` se usaba `String.fromCharCodes` (Latin-1), que rompe los
  acentos de un UTF-8. Ahora UTF-8 con respaldo Latin-1 (`decodeFileBytes`).
- **Filas que no son canciones:** `Type` = `Album`/`Artist` (álbumes y artistas guardados de la
  biblioteca) se saltan.
- **Varias playlists en un archivo:** se reparten por `Playlist name` y cada una se importa como
  playlist propia con su nombre original.
- **Etiquetas de Amazon** (`[Explicit]`, `[Clean]`) se quitan de título y álbum.
- **ISRC como último recurso** (`/track/isrc:{isrc}`, verificado en vivo): solo si la búsqueda no
  encontró nada, porque Deezer a veces cuelga la grabación de una recopilación
  (`docs/fuentes_youtube_y_matching.md`). Exige que el título se parezca.

## Código muerto quitado

Sin ninguna referencia en `lib/`, `test/` ni fuera de Dart: `lib/app_router.dart` (re-export sin
uso), `CoverCacheService.getCover` y `pruneOrphanCovers`, `DartFetchBridge.clearSession`,
`ExtractionIsolate.hasPendingRequests`, `EngineManager.brokenStreakKeys`, `engineSha256OfCode`,
`AppLimits.folderNameMax` (las carpetas usan `FolderService.maxNameLength`), `AppTheme.bgDark`,
`DownloadedTrackDao.getTotalSizeBytes`, `FolderDao.watchFolder`,
`PlaylistDao.searchTracksInPlaylist` y `findTracksByArtistIds`,
`SupabasePlaylistRepository.reorderTracks`, `DownloadService.getDownloadedTracksCount` y
`countDownloaded`, `watchDownloadedTrackProvider`, `SyncoraPlayerState.isSkipSilence`,
`SyncoraPlayerController.setSkipSilence`, el enum `RepeatMode` sin uso y `StatsPeriod.longLabel`.

**Muerto pero no quitado** (entretejido con el flujo de descargas; quitarlo es tocar su núcleo):
`DownloadService.progressStream` (el `StreamController` emite sin oyentes; es broadcast, no acumula)
y `cancelDownload` / `cancelAll` (nadie los llama, así que las comprobaciones de cancelación del
flujo nunca se activan). También quedan funciones públicas que solo usan los tests (`pickBest`,
`bestByDuration`, `filterMatchingTitle`, etc.).

## Reparar URLs de r2.dev (paso manual)

Primero comprobar (SQL Editor de Supabase):

```sql
select id, avatar_url from profiles where avatar_url like '%.r2.dev/%';
select id, title, cover_url from playlists where cover_url like '%.r2.dev/%';
```

Si sale algo, cambiar el dominio por el del Worker (el mismo valor que `R2_PUBLIC_BASE_URL`); el
sync reescribe `cover_url` en cada dispositivo y el perfil se vuelve a leer al abrir la app:

```sql
update profiles
set avatar_url = regexp_replace(avatar_url, '^https://[^/]+\.r2\.dev/', 'https://syncora-images.<subdominio>.workers.dev/')
where avatar_url like '%.r2.dev/%';

update playlists
set cover_url = regexp_replace(cover_url, '^https://[^/]+\.r2\.dev/', 'https://syncora-images.<subdominio>.workers.dev/')
where cover_url like '%.r2.dev/%';
```

Alternativa sin SQL: volver a subir la foto de perfil desde la app.
