# Syncora Player — Fase 4: Correcciones y Arquitectura Técnica

Este documento registra los ajustes técnicos y arquitectónicos aplicados durante la Fase 4 que son relevantes para las fases futuras (**Fase 5: Nube & Supabase**, **Fase 6: Motor Offline** y **Fase 7: Experiencia Premium & IA**).

---

## 1. Extracción y Matching de Audio (Deezer ➔ YouTube)

### Eliminación del Fallback Falso
- Se removió la respuesta simulada de éxito que devolvía un MP3 de prueba de SoundHelix de ~6 minutos cuando fallaba la resolución de un ID no-YouTube.
- Ahora, ante la imposibilidad de resolver una coincidencia válida, el sistema retorna de forma limpia `ExtractionFailure(error: ExtractionError.notFound)`, permitiendo al reproductor tomar decisiones de control (como Auto-Skip o notificación en UI).

### Migración de `YtMatcherService` a Innertube Search Client-Side
- Se eliminó completamente el servicio de scraping HTML obsoleto `lib/core/extraction/yt_matcher_service.dart`, el cual sufría de bloqueos e intermitencias por el muro de cookies de consentimiento de Google (`RedirectException`).
- La resolución de coincidencias por título y artista para pistas externas (Deezer / Locales) ahora se realiza directamente en el entorno QuickJS (`ExtractionIsolate`) usando la API de búsqueda de Innertube (`searchVideos`).

### Tubería de Búsqueda de 3 Niveles en JS
Para garantizar máxima resiliencia ante cambios en las respuestas de la API de YouTube, `searchVideos` implementa tres niveles de consulta:
1. **Nivel 1 (`yt.search`)**: Búsqueda estándar mediante el parser de `youtubei.js`.
2. **Nivel 2 (Raw JSON Fallback `yt.actions.execute`)**: Si el Nivel 1 falla por errores de tipos de encabezado UI (`SearchMobileHeader`), se consulta la acción `/search` directa recuperando el JSON de Innertube. La función `extractVideoCandidatesFromRaw` recorre la estructura extrayendo los nodos `videoRenderer` y `compactVideoRenderer`. Al ser una extracción sobre JSON puro, es 100% inmune a cambios de clases AST.
3. **Nivel 3 (`yt.music.search`)**: Fallback secundario a la API de YouTube Music.

### Selección de Clientes por Responsabilidad
- **Búsqueda (`searchVideos`)**: Utiliza el cliente `WEB`. La API web devuelve listas de resultados estándar (20 candidatos) en **~200 ms** sin conflictos de tipos de encabezado móviles.
- **Extracción de Stream URL (`extractVideo`)**: Utiliza el cliente `ANDROID`. El endpoint `/player` de Android entrega URLs directas de `googlevideo.com` (`itag 18`, MP4/AAC 128 kbps) de forma estable y sin requerir descifrado de firmas complejas.

### Motor de Scoring en Dart (`YtSearchMatcher`)
Dart analiza los 20 candidatos devueltos por la búsqueda mediante la clase `YtSearchMatcher`:
- **Duración**: Comparación contra la duración de Deezer ($\le 3\text{s} \to +100$, $> 30\text{s} \to -50$).
- **Filtro de Calidad**: Penalización de covers, karaokes o remedos ($-80$) y bonificación a audios oficiales o VEVO ($+30$).
- **Coincidencia de Artista**: Normalización de cadenas, minúsculas y acentos ($+50$).
- **Caché en Memoria**: La coincidencia resuelta (`DeezerTrackId` ➔ `YoutubeVideoId`) se almacena en memoria (`_resolvedMatchCache`) para reducir la latencia a **0 ms** si la pista se vuelve a reproducir en la misma sesión.

### Optimización de Cold Start (< 2s) vía `retrieve_player: false`
- Por defecto, `Innertube.create()` descargaba de YouTube el script del reproductor ejecutable (`base.js` de ~3 MB) a través del puente HTTP de QuickJS, consumiendo ~20 segundos en el arranque inicial.
- Se configuró `retrieve_player: false` en `InnertubeClass.create`. Dado que las transmisiones de audio estándar (`itag 18`) incluyen la URL directa en `streamingData.formats` sin requerir descifrado de firma de `base.js`, la descarga se omite.
- La creación del cliente pasó de **20 segundos a < 300 ms**, logrando reproducción inicial en **menos de 2 segundos**.

### Control de Sangrado de Audio y Peticiones Canceladas
- **Eliminación de Sangrado de Audio**: En `SyncoraPlayerController.playCurrent()`, se ejecuta `await _engine.pause()` al inicio de la llamada para silenciar en **0 ms** cualquier muestra de audio que quedara en buffer de la canción previa mientras se resuelve la nueva URL.
- **Resiliencia ante Next Continuo (`ExtractionError.cancelled`)**: Se agregó el enum `ExtractionError.cancelled` y una guardia en `_handleExtractionError` para ignorar silenciosamente respuestas de peticiones anteriores canceladas por cambios rápidos de pista, evitando que interrumpan la nueva canción en curso.
- **Silenciamiento de Logs**: Se sobrescribieron los métodos de `console.log` en el polyfill de JS para filtrar automáticamente advertencias redundantes del AST parser (`[YOUTUBEJS][Parser]`), manteniendo la consola limpia y evitando sobrecargar el isolate.

---

## 2. Persistencia y Gestión de Base de Datos Local

- **Esquema Reactivo Drift**: Definición de tablas `Playlists`, `PlaylistTracks`, `SavedAlbums` y `ListeningHistory`.
- **Acceso Offline Desnormalizado**: La tabla `PlaylistTracks` almacena copias de los metadatos principales (`title`, `artistName`, `albumName`, `coverUrl`, `durationMs`) para permitir renderizado instantáneo de la biblioteca e historial sin requerir conectividad de red.
- **Bypass de Pruebas**: Configuración de `NativeDatabase.memory()` en entorno de pruebas para evitar bloqueos por SQLite nativo en disco.

---

## 3. Consideraciones de Entorno para Pruebas (`_isTestEnv` / `FLUTTER_TEST`)

- Se implementó la guardia `Platform.environment.containsKey('FLUTTER_TEST')` en controladores, fábricas de motor de audio, widgets animados y adaptadores del SO.
- Evita la inicialización de controles FFI nativos de Windows (`SMTCWindows`), aislantes pesados de QuickJS o timers de shimmer durante la ejecución de `flutter test`.
- Mantiene la suite con **45/45 pruebas aprobadas** y **0 errores de análisis estático** (`dart analyze`).
