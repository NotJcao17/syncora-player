# Inicio y Explorar — rediseño post-Fase 7

**Fecha:** 2026-09-17
**Estado:** implementado (bundles A, B y C), pendiente de pruebas en dispositivo.

Esta ronda rehace la pantalla de Inicio, hace funcionales los botones de género de Búsqueda y
agrega tres pantallas nuevas (playlist de Deezer, género, mix).

---

## 1. Qué expone la API pública de Deezer (verificado en vivo, 2026-09-17)

Todo lo de esta tabla se probó con peticiones reales. **No hace falta volver a investigarlo.**

### Endpoints que ya usábamos

`/search[/track|artist|album]`, `/track/{id}`, `/track/{id}/related`, `/album/{id}`,
`/artist/{id}`, `/artist/{id}/top`, `/artist/{id}/albums`, `/artist/{id}/radio`,
`/artist/{id}/related`, `/chart/0/{tracks,albums,playlists}`.

### Endpoints nuevos incorporados en esta ronda

| Endpoint | Qué devuelve |
| :--- | :--- |
| `/genre` | 27 géneros con id, nombre **ya localizado por región** (desde México: "Reggaetón", "Música Mexicana", "Clásica") e imagen oficial hasta 1000 px. El id 0 es el comodín "Todos", no un género. |
| `/chart/{genre_id}` | **En una sola petición**: `tracks`, `albums`, `artists`, `playlists`, `podcasts` del género. Es lo que alimenta toda la pantalla de género. |
| `/genre/{id}/radios` | Radios editoriales del género (37 solo para Pop). |
| `/radio/{id}/tracks` | 25 pistas listas para reproducir. **No determinista** (ver §2). |
| `/playlist/{id}` | Playlist completa con `tracks.data`. Objeto estable, a diferencia de las radios. |
| `/user/637006841/playlists?limit=100` | Las **102 playlists "Top {país}" oficiales** de Deezer (usuario `Deezer Charts`), de 100 pistas cada una: Top Worldwide, Top Mexico, Top Brazil, Top Japan, Top France… Una sola petición para el catálogo entero. |
| `/album/{id}` → `genre_id` | Única fuente barata de género para algo que el usuario ya escuchó. |

### Probados y descartados

- **`/editorial/{id}/releases` está muerto**: devuelve `{"data":[],"total":0}` con cualquier id
  (probado con 0, 132, 152). **Deezer no tiene endpoint de novedades.** Las novedades se calculan
  en cliente filtrando `/artist/{id}/albums` por `release_date` (`MixEngine.filterRecentReleases`).
- **`/radio/top`** devuelve `{"error":{"type":"Exception"}}`.
- **`/artist/{id}/playlists`** trae ruido sin relación con el artista (para Coldplay devolvió
  "Star Academy 2025/2026").
- `/chart/0/albums` son los álbumes **más escuchados**, no los más nuevos — solo sirve de respaldo.

### Límites duros

- Sin API key **no hay usuario de Deezer**: no existe Flow ni ninguna personalización del lado de
  ellos. Toda la personalización sale de nuestro `listening_history`.
- `/chart/0` es **geo-IP**, sin parámetro de país. Los tops por país solo se consiguen por las
  playlists de `Deezer Charts`.
- Rate limit 50 req/5 s por IP, ya cubierto por el `RateLimiter` de `DeezerApi`.

### Billboard: descartado

No hay API pública oficial (Billboard cerró la suya; hoy solo licencia comercial). Las opciones
eran scrapers de terceros en RapidAPI (de pago, ToS gris) o el dataset abierto
`mhollingshead/billboard-hot-100` en GitHub, que **sí está vivo y actualizado semanalmente**, pero
cuyas entradas son solo texto `{song, artist}`: reproducirlo exigiría matchear 100 búsquedas contra
Deezer. Se decidió no incorporarlo — los tops de Deezer cubren el caso.

---

## 2. Hallazgo clave: las radios de Deezer no son estables

Pedir `/artist/{id}/radio` y `/radio/{id}/tracks` **dos veces con un segundo de diferencia devuelve
listas distintas** (verificado). Una radio es un generador, no una colección. Consecuencias de
diseño, ya implementadas:

- **No se puede "seguir" una radio**: no hay nada estable a lo que apuntar.
- **Syncora no sigue ninguna playlist remota, ni siquiera las que sí son estables.** Guardar es
  **copiar** (`save_collection_service.dart`). El motivo es que nuestro modelo de biblioteca copia
  pistas a `playlist_tracks`, lo que da gratis offline, descarga y edición; una playlist "seguida"
  necesitaría estado no editable en toda la UI y reglas nuevas de sync. **Decisión cerrada, no es
  una fase 8 pendiente.**

---

## 3. Cómo funcionan los mixes

Implementación en `lib/features/home/mixes/`.

### "On Repeat" es una playlist permanente, no un mix

Decisión revisada tras la segunda ronda de pruebas. Como snapshot no funcionaba: al reiniciar la
app se generaba otro y había que volver a guardarlo, acumulando copias fechadas en la biblioteca.
Es el mismo modelo que usa Spotify para sus playlists de sistema, y el mismo que "Tus me gusta"
acá: **existe siempre, aparece en Biblioteca, se regenera sola en el sitio cada semana y no se
edita a mano** (`on_repeat_service.dart`).

Se identifica por `playlists.sourceRef = 'mix:on_repeat:<semana>'` con `isGenerated = true`. Solo
vive en local — `remoteId` nulo, así que `SyncService` ni la ve (solo poda playlists que sí lo
tienen), y además el match por título del sync excluye las generadas para que una playlist remota
homónima no la adopte. Si en algún momento no hay historial suficiente, **se deja la de la semana
pasada** en vez de vaciarla.

### Los demás mixes siguen siendo efímeros

`mixesProvider` es un `FutureProvider` **no `autoDispose`** a propósito: se construye una vez por
arranque y vive en memoria, así que entrar y salir de un mix muestra siempre la misma lista. Al
reabrir la app se generan de nuevo. Guardar uno crea una **copia congelada** con fecha en el
nombre.

Como el `sourceRef` de esa copia lleva pegada la clave del mix, y la clave lleva su periodo,
cuando el mix se regenera el botón vuelve a ofrecer guardarlo solo: la copia que existe es del mix
anterior.

**Cadencias** (claves de periodo calculadas en cliente, `MixEngine.weekKey`/`dayKey` — **sin cron,
sin servidor**): On Repeat semanal sobre una ventana de 30 días; artista, género, descubrimiento y
radios, diarios. Dentro del periodo la selección "al azar" es determinista
(`shuffleDeterministic` con semilla derivada de la clave).

| Mix | Cuántos | Fuente |
| :--- | :--- | :--- |
| On Repeat | 1, permanente | historial local, ≥2 escuchas en 30 días, resuelto contra `playlist_tracks` y descargas antes de tocar la red (`TrackResolver`, tope de 6 lookups remotos) |
| Mix de {artista} | 4 | `/artist/{id}/radio` de sus top artistas |
| Mix de {género} | 2 | álbumes más escuchados → `genre_id` → `/chart/{genre_id}` |
| Descubrimiento | 1 | `/artist/{id}/related` → radio de un relacionado, quitando lo ya escuchado |
| Radios editoriales | 2 | `/genre/{id}/radios` de su género dominante |

Un "Mix de {artista}" trae pocas canciones de ese artista (3 de 25 para Bruno Mars, medido): es lo
que devuelve `/artist/{id}/radio`, que es una radio de artistas parecidos. **Se decidió dejarlo
así** — intercalar sus top tracks los repetiría siempre, porque el top de un artista no cambia.

### Guardar una colección: estado y descarga

`playlists.sourceRef` (`deezer_playlist:1234`, `mix:<clave>`) es lo que permite que el botón de
guardar tenga estado. Sin él no había forma de saber que la copia existía: el icono no cambiaba al
guardar, el usuario creía que no había pasado nada, volvía a pulsarlo y terminaba con la misma
playlist dos veces. Ahora el botón muestra "Guardada" y lleva a la copia.

Descargar una colección que no está en la biblioteca **la guarda primero**, en el mismo gesto: si
no, quedaban pistas descargadas sin ninguna colección a la que pertenecieran, y en el caso de un
mix dejarían de corresponder a nada en cuanto se regenerara.

## 4. Caché de catálogo

`lib/core/cache/api_cache.dart`: caché en archivos con TTL, escritura atómica y capa en memoria
acotada a 24 entradas. **No usa Drift** para no tener que subir `schemaVersion` y escribir una
migración por lo que es, literalmente, un archivo con fecha.

TTLs: catálogo estable (géneros, tops por país, fichas de artista/álbum) 7 días; charts y
editoriales 6 h; discografías 24 h. **Las radios no se cachean nunca** (§2).

Si la red falla y hay una copia vencida, se devuelve la copia vencida en vez de propagar el error:
más vale un chart de ayer que una pantalla vacía. Esto es lo que hace que Inicio ya no arranque en
blanco ni quede vacía sin conexión.

---

## 5. Pantalla de Inicio

Orden pensado para que **lo local se pinte primero** (todo lo de las cuatro primeras secciones sale
de Drift: aparece en el primer frame y funciona sin red):

1. Saludo, avatar, ajustes
2. Accesos rápidos (Tus me gusta, Descargas, Estadísticas)
3. **Escuchado recientemente** — primer consumidor real de `playlists.lastPlayedAt` y
   `savedAlbums.lastPlayedAt`, que se escribían desde la ronda 3 y nadie leía
4. **Tus mixes** — On Repeat primero, después los efímeros (hasta 9)
5. **Novedades de tus artistas** (respaldo: álbumes destacados del chart)
6. **Tops del mundo** — destacados con México primero, y "Ver todos" abre un selector buscable con
   los 102 países (diálogo centrado en PC, hoja en móvil)
7. **Playlists editoriales** (50; el endpoint acepta hasta 100 y no le estábamos mandando `limit`)
8. **Porque escuchaste a {artista}** — dos secciones, una por cada uno de sus dos artistas más
   escuchados, sin repetir artistas entre ellas
9. **Explorar por género**

**Regla de diseño:** ninguna canción individual se presenta como si fuera una colección. Todas las
tarjetas son playlists, álbumes, mixes, artistas o géneros. Por eso desapareció la sección
"Éxitos Globales", que pintaba cinco canciones sueltas: la reemplaza Top Worldwide.

El panel "Tu semana" que estuvo arriba se quitó. El dashboard de estadísticas de la Fase 8 decidirá
si vuelve y con qué diseño; los datos salen de `stats_providers.dart`, que no se tocó.

Coste: ~12 peticiones en el primer arranque, 0–2 en los siguientes gracias al caché.

---

## 6. Bugs corregidos de paso

1. **Las playlists editoriales no llevaban a ningún lado**: su `onTap` era
   `AppToast.show(context, message: 'Playlist: ...')`. Ahora abren `/deezer-playlist/:id`.
2. **"Top Global 50" del acceso rápido** navegaba a `/search` y su portada era una URL con el hash
   MD5 de la cadena vacía — imagen rota permanente. Eliminado; los tops tienen su propia sección.
3. **Los botones de género de Búsqueda solo escribían texto en el buscador** (el botón "Pop"
   buscaba el texto "pop"). Ahora abren `/genre/:id`, y los 6 géneros escritos a mano pasaron a ser
   los 27 reales de `/genre`, con imagen oficial.
4. **Personalización pobre**: `personalizedSectionsProvider` gastaba 6 peticiones para mostrar los
   top tracks de 3 artistas (lo mismo que ya se ve en la pantalla de artista) y, sin historial,
   caía a Coldplay/Bad Bunny/Dua Lipa hardcodeados. Sustituido por mixes y una degradación por
   contenido real (tops + editoriales + géneros).

## 7. Corregidos en la autorrevisión del diff

- El subtítulo del mix de descubrimiento sacaba el nombre de la semilla de la primera pista de la
  radio, que **no es el artista semilla** (una radio devuelve sobre todo canciones de otros), así
  que ponía un nombre casi al azar.
- La capa en memoria del caché no tenía techo: cada playlist abierta dejaba sus 100 pistas ya
  decodificadas vivas toda la sesión.
- `deezerPlaylistProvider` y `deezerGenreChartProvider` pasaron a `autoDispose` por el mismo motivo.

---

## 8. Hallazgos de la primera ronda de pruebas en dispositivo (2026-09-17)

### H-IE-1 — Duplicados masivos al instalar de cero (bug **preexistente**, no de esta ronda)

Instalar la app limpia sobre una cuenta ya poblada dejaba **cada playlist y cada "me gusta"
duplicados**, y reabrir no lo arreglaba.

Causa raíz: `SyncService` no tenía guarda de reentrancia y hay **tres disparadores** de
`syncLibrary` que pueden coincidir — iniciar sesión (`auth_screen`), arrancar la app
(`AppShell.initState`) y abrir Biblioteca. El chequeo `isExpired('library')` no los serializa
porque `markSynced` se escribe **al terminar**: las tres corridas pasaban el chequeo, las tres
leían la base local vacía y las tres insertaban lo mismo.

Y se agravaba solo: con dos filas compartiendo `remoteId`, `getPlaylistByRemoteId` usaba
`getSingleOrNull()`, que **lanza**, y el `catch (_) {}` de `SyncService` se comía la excepción —
la sincronización quedaba rota en silencio para siempre.

Corregido con: guarda de reentrancia (`_runExclusive`), consultas tolerantes a filas repetidas
(`getPlaylistByRemoteId`, `getLikedPlaylist`, `isTrackLiked`), deduplicación de lo que llega del
servidor, y `PlaylistDao.repairDuplicates()` corriendo en cada arranque para sanar las bases que
ya quedaron sucias (nadie tiene que borrar los datos de la app a mano). Cubierto por
`test/data/local_db/daos/playlist_repair_test.dart` y un test de concurrencia en
`sync_service_test.dart`.

⚠️ **Trampa de Dart que costó encontrar** (documentada en el código): la primera versión de la
guarda usaba `action().whenComplete(() => _inFlight.remove(key))`. `Map.remove` **devuelve** el
valor quitado — que es el propio `Future` que se está registrando — y `whenComplete` espera a lo
que devuelva su callback: el future terminaba esperándose a sí mismo y la sincronización se
colgaba para siempre. Cuerpo de bloque, nunca flecha.

### H-IE-2 — `/chart/{genre_id}` devuelve los mismos artistas para todos los géneros

Verificado en vivo: `tracks`, `albums` y `playlists` sí cambian con el género, pero `artists`
contesta **la misma lista global** con cualquier `genre_id`, y `/genre/{id}/artists` tiene el mismo
defecto. Por eso "Artistas de Rock" mostraba a Peso Pluma y La Arrolladora. Es una limitación de
Deezer, no un bug nuestro. Solución: los artistas del género se **derivan de sus pistas**, que sí
son del género, y la foto sale de `https://api.deezer.com/artist/{id}/image` (302 → CDN), sin
peticiones extra.

### H-IE-3 — `/artist/{id}/albums` no trae el objeto `artist`

Por eso "Novedades de tus artistas" mostraba "Artista Desconocido" en todo. El nombre se rellena
en el provider con la ficha del artista, que ya está cacheada.

### H-IE-4 — Los carruseles no se podían recorrer en escritorio

Un `ListView` horizontal solo responde a gestos táctiles: Flutter excluye el ratón de
`dragDevices` y la rueda desplaza la página en vertical. En Windows el usuario veía las primeras
tarjetas y no tenía **ninguna** forma de llegar al resto. Resuelto con
`core/widgets/horizontal_scroller.dart`: arrastre con ratón habilitado más flechas en los bordes
al pasar el cursor. Deliberadamente **no** se secuestra la rueda del ratón — sobre un carrusel
debe seguir desplazando la página.

### H-IE-5 — Reproducción lenta al arrancar (mitigado, causa **no confirmada**)

Reportado como "tarda más y va trabada al empezar". No se perfiló, así que no está confirmado qué
lo causa. Mitigación aplicada sobre la hipótesis más plausible (la ráfaga de trabajo que Inicio
dispara al montarse compitiendo con el arranque del reproductor): los providers derivados del
historial esperan a que termine el primer frame (`settleAfterFirstPaint`), y el tope de búsquedas
remotas de `TrackResolver` bajó de 12 a 6. **Requiere volver a probarlo en dispositivo**; si sigue
igual, hay que perfilar en vez de seguir adivinando.

## 9. Pendiente

- Pruebas en dispositivo (Android y Windows) de las cuatro pantallas nuevas.
- El bug reportado de "Inicio vieja y después la nueva" no se pudo reproducir y es de hace varias
  fases. No se encontró ninguna pantalla de Inicio duplicada en el código (hay un solo
  `HomeScreen`, y `/` y `/home` apuntan al mismo). Las dos hipótesis que quedaron sin descartar
  son un parpadeo de layout móvil→escritorio en el primer frame de Windows
  (`isDesktop = width >= 768`) y un doble montaje por el redirect de auth. Inicio se reescribió
  entera en esta ronda, así que conviene volver a mirarlo en las pruebas de dispositivo.
