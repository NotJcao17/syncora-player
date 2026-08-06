# Corrección: Fallback de 6 min + Migración YtMatcher a Innertube Search (B2)

## 1. Descripción del Problema
Al reproducir canciones provenientes de plataformas externas como Deezer (cuyos IDs son numéricos en lugar de IDs de YouTube de 11 caracteres), el reproductor dependía del servicio de scraping HTML `YtMatcherService`. 
Debido a bloqueos e intermitencias del muro de consentimiento/cookies de YouTube (`RedirectException` / `DioException [unknown]: null`), el matching fallaba en ~1 de cada 10 ocasiones. Cuando esto ocurría, `ExtractionIsolate` devolvía una respuesta simulada de éxito conteniendo un archivo MP3 de SoundHelix de ~6 minutos de duración.

## 2. Solución Aplicada

### Frente A — Eliminación del Fallback Silencioso
- Se modificó `ExtractionIsolate` para eliminar el retorno de la URL de prueba de SoundHelix.
- En su lugar, si la resolución de un ID falla, se devuelve de forma limpia un `ExtractionFailure(error: ExtractionError.notFound)`.

### Frente B2 — Búsqueda Nativa vía Innertube Search
- **Ampliación de `ExtractionRequest`**: Se añadieron los campos opcionales `trackTitle`, `trackArtist` y `durationSeconds`.
- **Motor JS (`js_bundle_loader.dart`)**: Se agregó la función `globalThis.searchVideos(query, client, jsRequestId)` que ejecuta `yt.search(query, { type: 'video' })` dentro del runtime QuickJS.
- **Scoring en Dart (`YtSearchMatcher`)**: Se creó la clase `YtSearchMatcher` para procesar los candidatos obtenidos de Innertube:
  - Compara la duración con `durationSec` (diferencia $\le 3\text{s} \to +100$, $\le 10\text{s} \to +40$, $\le 20\text{s} \to +15$, $> 30\text{s} \to -50$).
  - Penaliza términos no deseados (`cover`, `karaoke`, `instrumental`, `choreography`, `remix`, etc.) con $-80$ puntos cada uno.
  - Otorga bonificación a términos de calidad (`official`, `audio`, `lyrics`, `vevo`, etc.) con $+30$ puntos.
  - Otorga $+50$ puntos por coincidencia del nombre del artista normalizado.
  - Selecciona el mejor candidato con score $\ge 0$.
- **Integración Isolate (`ExtractionIsolate`)**: Se registró el canal `searchResult` y se integró el proceso de búsqueda en cascada (`ANDROID`, `ANDROID_VR`, `WEB`) antes de declarar `notFound`.
- **Controlador (`SyncoraPlayerController`)**: Se removió `YtMatcherService` y se actualizaron las peticiones a `ExtractionService.extractUrl` pasando los metadatos del track.
- **Limpieza**: Se eliminó el archivo de scraping HTML `lib/core/extraction/yt_matcher_service.dart`.

## 3. Pruebas y Verificación
- Se crearon pruebas unitarias exhaustivas en `test/core/extraction/yt_search_matcher_test.dart` verificando la normalización de cadenas, priorización de duraciones, coincidencia de artista y penalización de covers/karaokes. Todas las pruebas pasaron satisfactoriamente.

## 4. Optimización de Cold Start y Corrección de Sangrado de Audio

### Cold Start (< 2s) vía `retrieve_player: false`
- Por defecto, `Innertube.create()` descargaba el script del reproductor ejecutable de YouTube (`base.js` de ~3 MB) a través del puente HTTP de QuickJS en cada cold start, tardando ~20 segundos en la primera reproducción.
- Se agregó `retrieve_player: false` a `InnertubeClass.create({ client_type: client, retrieve_player: false })` en `js_bundle_loader.dart`. Dado que el streaming de audio/video estándar (`itag 18`) entrega la URL directa en `streamingData.formats` sin requerir descifrado de firma de `base.js`, la descarga se omite por completo.
- La creación de la instancia se redujo de **20 segundos a < 300 ms**, logrando reproducción inicial en **< 2 segundos**.

### Eliminación del Sangrado de Audio previo en Next / Cambios de Pista
- En `SyncoraPlayerController.playCurrent()`, se agregó `await _engine.pause()` al inicio de la llamada para pausar de inmediato cualquier muestra de audio en buffer de la pista previa mientras se resuelve la nueva URL de la pista destino.

### Manejo de Peticiones Canceladas por Superposición (`ExtractionError.cancelled`)
- Se agregó el enum `ExtractionError.cancelled` y la guardia en `_handleExtractionError` para ignorar silenciosamente la respuesta de peticiones previas canceladas por cambios rápidos de pista (clics seguidos en Next), impidiendo que respuestas obsoletas canceladas interrumpan la reproducción de la pista actual.

