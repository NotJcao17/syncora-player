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
