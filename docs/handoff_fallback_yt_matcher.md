# HANDOFF: Fix fallback de 6 min + migrar YtMatcher a Innertube search (B2)

> **Para el agente que recibe esto:** este documento es **autocontenido**. Contiene el
> problema, la solución aprobada, el plan de implementación detallado y —lo más
> valioso— **toda la evidencia de la API de youtubei.js ya recopilada** para que NO
> tengas que re-investigar el bundle JS minificado (eso consumió ~40% de la cuota del
> agente anterior). Lee `docs/Documento_Maestro.md` y `docs/fases/fase_1.md` para
> contexto de arquitectura si lo necesitas.

---

## 1. EL PROBLEMA

### Síntoma
Al reproducir algunas canciones, en vez de la canción real suena **un audio de
~6 minutos (6:12 aprox.)**. Es un MP3 de SoundHelix usado como "fallback de prueba".

### Logs que se ven
```
[YtMatcher] Error buscando en YouTube: DioException [unknown]: null
Error: RedirectException: Redirect loop detected
Error: RedirectException: Redirect limit exceeded
```
Estos errores **NO** son del motor de extracción JS (que funciona y loguea
`[JS ÉXITO] URL obtenida correctamente!`). Son del **otro** sistema: el `YtMatcherService`
(scraping HTML de `youtube.com/results`).

### Causa raíz (cadena completa)
1. La pista viene de **Deezer** → su `id` es numérico (ej. `"562149682"`), NO es un ID
   de YouTube, y `track.youtubeVideoId` es `null`.
2. `playCurrent()` (`lib/features/player/syncora_player_controller.dart:286`) detecta que
   no es de 11 chars → llama a `YtMatcherService`.
3. `YtMatcherService` **falla** (su Dio se atasca en el muro de consentimiento/cookies de
   YouTube → `RedirectException`) → devuelve `null`.
4. `targetId` se queda como el ID numérico → llega al isolate.
5. **`lib/core/extraction/extraction_isolate.dart:282-292`** detecta que no es de 11 chars
   y **devuelve el MP3 de SoundHelix disfrazado de `ExtractionSuccess`**:
   ```dart
   if (!is11CharYtId) {
     return ExtractionSuccess(
       streamUrl: 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3',
       ...  // ¡esto es el audio de 6 min!
     );
   }
   ```
6. Suena la canción de 6 minutos.

### Comportamiento real observado por el usuario (¡importante!)
El sistema funcionaba con **~9 de cada 10 canciones, incluso sin haberse escuchado
nunca**. Es decir, el `YtMatcherService` (scraping HTML) **sí resolvía la mayoría de las
veces**. El error `RedirectException` **no ocurre siempre**, solo **a veces** (YouTube
sirve el muro de consentimiento de forma intermitente — por IP, carga, A/B). El bug del
audio de 6 min aparece precisamente en ese ~10% donde el scraper cae esa vez.

**El motor de extracción JS NO es el problema y nunca lo fue** — loguea `[JS ÉXITO]` y
funciona. El problema es exclusivamente el matcher del Main Isolate que le precede, y el
fallback silencioso que se dispara cuando ese matcher falla. **No tocar el motor de
extracción.**

Consecuencia para la solución: el scraper HTML es inherentemente **variable** (depende de
si YouTube te suelta el consentimiento esa vez), por eso es "9/10". La migración a
**Innertube search** (API JSON, sin muro de consentimiento) elimina esa intermitencia y
pasa a ser consistente.

### Por qué el YtMatcher actual falla (definición de Dio)
`lib/core/extraction/yt_matcher_service.dart:10-22`:
```dart
Dio(BaseOptions(
  connectTimeout: ..., receiveTimeout: ...,
  headers: { 'User-Agent': '...', 'Accept-Language': '...' },
))   // ← NO followRedirects, NO validateStatus, NO CookieManager
```
YouTube, sin cookies de consentimiento, redirige a `consent.google.com` que rebota sin
fin → redirect loop. El `DioException [unknown]: null` es el `toString()` de Dio cuando
la causa envuelta es una `RedirectException` sin respuesta HTTP.

---

## 2. LA SOLUCIÓN APROBADA (A + B2)

**Decisión del usuario (confirmada):** hacerlo lo más robusto posible.

- **Frente A — Quitar el fallback silencioso** (obligatorio). El MP3 de SoundHelix nunca
  debe devolverse como `ExtractionSuccess` en producción.
- **Frente B2 — Migrar el matcher a Innertube search** (dentro del isolate QuickJS, el
  mismo motor que ya funciona). Usar `yt.search(query, { type: 'video' })`.
- **Sin B1** (no mantener el scraper HTML como fallback: es frágil, duplica mantenimiento
  y va contra la arquitectura documentada).
- **B3 (persistencia en tabla `yt_matches`) queda para la Fase 5.**

### Bonus: mejora real del "filtrado"
El "sistema para evitar coreografías/covers" que el usuario creía tener **hoy es solo**
`yt_matcher_service.dart:51`: añadir `"official audio"` al query y coger **el primer**
`videoId` del HTML. No hay filtrado real. B2 da la oportunidad de construir un **scoring
real** (duración, términos penalizados/bonificados, coincidencia de artista). Esto es
parte del plan (Cambio 2d) y el usuario lo pidió explícitamente conservar/mejorar.

---

## 3. EVIDENCIA DE LA API DE youtubei.js (YA RECOPILADA — NO RE-INVESTIGAR)

El bundle está en `assets/js/youtubei.bundle.js` (42133 líneas, minificado). El método
principal de búsqueda vive en la clase `Innertube`. Hallazgos verificados:

### 3.1 Método de búsqueda (offset 1617528 en el bundle)
```js
async search(query, filters = {}) {
  throwIfMissing({ query });
  const search_filter = {};
  search_filter.filters = {};
  if (filters.prioritize) {
    search_filter.prioritize = SearchFilter_Prioritize[filters.prioritize.toUpperCase()];
  }
  if (filters.upload_date) {
    search_filter.filters.uploadDate = SearchFilter_Filters_UploadDate[filters.upload_date.toUpperCase()];
  }
  if (filters.type) {
    search_filter.filters.type = SearchFilter_Filters_SearchType[filters.type.toUpperCase()];
  }
  if (filters.duration) {
    search_filter.filters.duration = SearchFilter_Filters_Duration[filters.duration.toUpperCase()];
  }
  ...
}
```
**→ Llamada correcta:** `await yt.search('query', { type: 'video' })`.
El `type: 'video'` filtra canales/playlists. Los strings de filtro se convierten con
`.toUpperCase()` antes de mapearlos al enum.

### 3.2 Enum SearchType (offset 160494) — confirma que `type:'video'` funciona
```js
SearchType = {
  ANY_TYPE: 0, VIDEO: 1, CHANNEL: 2, PLAYLIST: 3, MOVIE: 4, SHORTS: 9, ...
}
```

### 3.3 Enum Duration (offset 160765) — ¡IMPORTANTE, NO usar short/medium/long!
```js
SearchFilter_Filters_Duration = {
  ANY_DURATION: 0,
  OVER_TWENTY_MINS: 2,
  UNDER_THREE_MINS: 4,
  THREE_TO_TWENTY_MINS: 5, ...
}
```
**→ Los valores son `THREE_TO_TWENTY_MINS`, etc., NO `short/medium/long`** (eso era de la
YouTube Data API v3). **Recomendación: NO usar el filtro `duration` en la búsqueda JS.**
Es más flexible hacer el filtrado fino de duración en el scorer de Dart (Cambio 2d), porque
una canción real puede caer en cualquier bucket.

### 3.4 Resultados de búsqueda
- `.videos` getter (offset 1217020): `return _Feed.getVideosFromMemo(...)` → lista de
  objetos `Video`.
- Cada `Video` (mapeo en offset 683027):
  - `this.title = new Text2(data.title);` → acceso **`v.title.text`**
  - `this.video_id = data.videoId;` → acceso **`v.id`** (vía getter `get id() { return this.video_id; }`)
  - `get duration()` (offset ~): usa `ThumbnailOverlayTimeStatus`/`length_text` → acceso **`v.duration.seconds`** (estándar youtubei.js)
  - `get author()` → acceso **`v.author.name`** (puede ser undefined en algunos resultados; usar optional chaining)

**→ Shape del candidato a devolver al Dart:**
```js
{ videoId: v.id, title: v.title?.text ?? '', author: v.author?.name ?? '', durationSec: v.duration?.seconds ?? null }
```

### 3.5 Patrón existente a seguir
El `extractVideo` ya en `js_bundle_loader.dart:486-646` muestra EXACTAMENTE el patrón a
replicar para `searchVideos`:
- Caché de instancias: `globalThis._ytInstances[client]` (línea 500-508).
- Creación: `yt = await InnertubeClass.create({ client_type: client })` (línea 503).
- Canal de respuesta: `sendMessage('extractionResult', JSON.stringify({...}))` (línea 630).
- Resolver `InnertubeClass`: líneas 490.

El canal del isolate ya está registrado (`extraction_isolate.dart:212-225` para
`extractionResult`). Hay que añadir un canal `searchResult` análogo.

---

## 4. PLAN DE IMPLEMENTACIÓN DETALLADO

### Cambio 1 — Frente A: quitar fallback silencioso
**`lib/core/extraction/extraction_isolate.dart:282-292`** — reemplazar:
```dart
final is11CharYtId = RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(videoId);
if (!is11CharYtId) {
  sendLog('[IsolateJS] ID "$videoId" no es un ID de YouTube de 11 caracteres.');
  return ExtractionFailure(
    requestId: request.requestId,
    error: ExtractionError.notFound,
    message: 'No se pudo resolver un ID de YouTube para "$videoId".',
  );
}
```
> Nota: este bloque se queda como red de seguridad defensiva. En la práctica casi nunca se
> ejecuta porque el Cambio 2e resuelve el ID antes. Si llega aquí es porque el matching
> también falló → skip limpio es lo correcto.

### Cambio 2 — Frente B2: matcher vía Innertube search

#### 2a. Ampliar `ExtractionRequest`
**`lib/core/extraction/models/extraction_request.dart`** — añadir campos opcionales:
```dart
class ExtractionRequest {
  final String videoId;
  final String requestId;
  final ExtractionPriority priority;
  final String? trackTitle;        // NUEVO
  final String? trackArtist;       // NUEVO
  final int? durationSeconds;      // NUEVO (de Deezer, para scoring)
  // actualizar constructor, toJson, fromJson
}
```

#### 2b. Nueva función JS `searchVideos`
**`lib/core/extraction/js_bundle_loader.dart`** — añadir al `postScript` (tras
`extractVideo`, antes del cierre `'''`). Patrón idéntico a `extractVideo`:
```js
globalThis.searchVideos = function(query, client, jsRequestId) {
  console.log('[JS] searchVideos iniciado query="' + query + '", client=' + client + ', reqId=' + jsRequestId);
  (async function() {
    try {
      var InnertubeClass = globalThis.Innertube || (globalThis.YouTubeJS ? (globalThis.YouTubeJS.Innertube || globalThis.YouTubeJS.default) : null);
      if (!InnertubeClass) {
        sendMessage('searchResult', JSON.stringify({ requestId: jsRequestId, error: 'Clase Innertube no encontrada.' }));
        return;
      }
      var yt = globalThis._ytInstances[client];
      if (!yt) {
        yt = await InnertubeClass.create({ client_type: client });
        globalThis._ytInstances[client] = yt;
      }
      var search = await yt.search(query, { type: 'video' });
      var videos = (search && search.videos) ? search.videos : [];
      var results = [];
      for (var i = 0; i < videos.length; i++) {
        var v = videos[i];
        results.push({
          videoId: v.id,
          title: (v.title && v.title.text) ? v.title.text : '',
          author: (v.author && v.author.name) ? v.author.name : '',
          durationSec: (v.duration && typeof v.duration.seconds === 'number') ? v.duration.seconds : null
        });
      }
      console.log('[JS] searchVideos OK: ' + results.length + ' candidatos');
      sendMessage('searchResult', JSON.stringify({ requestId: jsRequestId, results: results }));
    } catch (e) {
      console.log('[JS searchVideos EXCEPCIÓN] ' + (e ? e.toString() : 'unknown'));
      sendMessage('searchResult', JSON.stringify({ requestId: jsRequestId, error: e ? e.toString() : 'search error' }));
    }
  })();
};
```
**⚠ NO uses `{ type:'video', duration:'long' }`** — los valores de duration son
`THREE_TO_TWENTY_MINS` etc., no `long`. Omite el filtro duration; el scoring Dart lo maneja.

#### 2c. Canal `searchResult` en el isolate
**`lib/core/extraction/extraction_isolate.dart`**:
- Junto a `final Map<String, Completer<Map<String, dynamic>>> _jsExtractCompleters = {};`
  (línea 31), añadir: `final Map<String, Completer<Map<String, dynamic>>> _jsSearchCompleters = {};`
- Junto al handler `extractionResult` (línea 212-225), añadir handler análogo para
  `searchResult` que resuelva `_jsSearchCompleters[jsRequestId]`.
- Nueva función estática `_trySearchWithClient(query, client, jsRuntime, sendLog)` análoga
  a `_tryExtractWithClient` (línea 403-433): genera `jsRequestId`, crea completer, evalúa
  `globalThis.searchVideos('$query', '$client', '$jsRequestId')`, awaiting con timeout
  ~20s. Devuelve `List<Map<String,dynamic>>?` (los `results`) o null.

#### 2d. Scorer de matching (la mejora real del filtrado)
**Crear `lib/core/extraction/yt_search_matcher.dart`** (clase estática pura, sin red):
```dart
class CandidateVideo {
  final String videoId;
  final String title;
  final String author;
  final int? durationSec;
  final int score;
  CandidateVideo({required this.videoId, required this.title, required this.author, this.durationSec, required this.score});
}

class YtSearchMatcher {
  static const _badTerms = ['cover', 'karaoke', 'instrumental', 'choreography',
    'coreografia', 'tutorial', 'reaction', 'reaccion', 'remix', 'teaser', 'trailer'];
  static const _goodTerms = ['official', 'audio', 'lyric', 'lyrics', 'mv', 'vevo', 'm/v'];

  /// Normaliza: minúsculas, sin acentos, sin signos.
  static String _norm(String s) => ...;

  /// Devuelve el mejor candidato o null si ninguno supera el umbral.
  static CandidateVideo? pickBest(
    List<Map<String, dynamic>> candidates, {
    required String artist,
    required String title,
    int? durationSec,
  }) {
    // Para cada candidato, sumar score:
    //  1. Duración (si durationSec conocido):
    //     diff<=3s → +100, <=10s → +40, <=20s → +15, >30s → -50
    //  2. Términos malos en title/author (case/acento insensible) → -80 c/u
    //  3. Términos buenos en title → +30 c/u
    //  4. Artista aparece en author o title (norm) → +50
    //  5. Orden de relevancia → +(N-index)*2 (suave, para desempatar)
    // Elegir max score; umbral mínimo score >= 0 (o ajustable). Si ninguno → null.
  }
}
```

#### 2e. Integración en `_processExtraction`
**`lib/core/extraction/extraction_isolate.dart`** — en `_processExtraction`, ANTES del
bloque `if (!is11CharYtId)` que ahora devuelve `notFound`, intentar matching:
```dart
if (!is11CharYtId) {
  // Intentar matching vía Innertube search antes de fallar.
  if (request.trackTitle != null || request.trackArtist != null) {
    final query = '${request.trackArtist ?? ''} ${request.trackTitle ?? ''}'.trim();
    for (final client in ['ANDROID','ANDROID_VR','WEB']) {
      sendLog('[IsolateJS] Buscando match para "$query" con cliente $client...');
      final candidates = await _trySearchWithClient(query, client, jsRuntime, sendLog);
      if (candidates != null && candidates.isNotEmpty) {
        final best = YtSearchMatcher.pickBest(
          candidates,
          artist: request.trackArtist ?? '',
          title: request.trackTitle ?? '',
          durationSec: request.durationSeconds,
        );
        if (best != null) {
          sendLog('[IsolateJS] Match seleccionado: ${best.videoId} (score ${best.score}) para "$query"');
          // Reentrar al flujo de extracción con el ID ya resuelto (11 chars):
          final resolvedRequest = ExtractionRequest(
            videoId: best.videoId,
            requestId: request.requestId,
            priority: request.priority,
          );
          return _processExtraction(request: resolvedRequest, jsRuntime: jsRuntime, retryPolicy: retryPolicy, sendLog: sendLog);
        }
        sendLog('[IsolateJS] Ningún candidato superó el umbral de scoring con $client.');
      } else {
        sendLog('[IsolateJS] Búsqueda sin candidatos con $client.');
      }
    }
  }
  // Si el matching falla o no hay metadatos → notFound limpio (Cambio 1).
  return ExtractionFailure(
    requestId: request.requestId,
    error: ExtractionError.notFound,
    message: 'No se pudo resolver un ID de YouTube para "$videoId".',
  );
}
```

### Cambio 3 — Conectar en el controlador y limpiar el scraper viejo
**`lib/features/player/syncora_player_controller.dart`**:
- Eliminar `final YtMatcherService _ytMatcher = YtMatcherService();` (línea 97) y su import.
- En `playCurrent()` (líneas 286-292), quitar el bloque que llama a `_ytMatcher`. En su
  lugar, pasar metadatos a `extractUrl`:
  ```dart
  final result = await _extractionService.extractUrl(
    targetId,
    trackTitle: track.title,
    trackArtist: track.artist,
    durationSeconds: track.duration?.inSeconds,
    priority: ExtractionPriority.streaming,
  );
  ```
**`lib/core/extraction/extraction_service.dart`**:
- En la interfaz `ExtractionService.extractUrl(...)` y en `ExtractionServiceReal`/`ExtractionServiceMock`,
  añadir params opcionales `trackTitle, trackArtist, durationSeconds` y reenviarlos al
  `ExtractionRequest` (en Real). El Mock los ignora.
**Eliminar** `lib/core/extraction/yt_matcher_service.dart`.

### Cambio 4 — Tests
- **Crear `test/core/extraction/yt_search_matcher_test.dart`** (tests puros del scoring,
  sin red — el más valioso porque valida la mejora de filtrado sin tocar YouTube):
  - match por duración exacta gana;
  - penalización de "cover"/"karaoke" baja el ranking;
  - bonus de "official audio" sube;
  - caso sin candidatos válidos → `null`.
- Verificar que no haya otros tests referenciando `YtMatcherService` (búsqueda previa
  indicó que solo se usa en los 2 sitios listados, pero confirmar con grep).
- `multi_song_extraction_test.dart` ya está marcado `@Tags(['integration'])` — dejarlo.

### Cambio 5 — Documentación
- `docs/investigacion_y_pitfalls.md`: añadir pitfall — "el fallback de prueba nunca debe
  devolverse como `ExtractionSuccess` en producción" + nota del matching vía Innertube.
- `docs/fases/fase_4_correcciones.md` (crear) o añadir errata a `fase_4.md`: documentar el
  bug del fallback de 6 min, su causa y la migración del matcher a Innertube.

---

## 5. ARCHIVOS AFECTADOS (resumen)

| Archivo | Acción |
|---|---|
| `lib/core/extraction/extraction_isolate.dart` | Editar (Cambio 1 + 2c + 2e + canal searchResult) |
| `lib/core/extraction/js_bundle_loader.dart` | Editar (Cambio 2b: añadir `searchVideos`) |
| `lib/core/extraction/models/extraction_request.dart` | Editar (Cambio 2a) |
| `lib/core/extraction/extraction_service.dart` | Editar (Cambio 3) |
| `lib/core/extraction/yt_search_matcher.dart` | Crear (Cambio 2d) |
| `lib/core/extraction/yt_matcher_service.dart` | Eliminar (Cambio 3) |
| `lib/features/player/syncora_player_controller.dart` | Editar (Cambio 3) |
| `test/core/extraction/yt_search_matcher_test.dart` | Crear (Cambio 4) |
| `docs/investigacion_y_pitfalls.md` + `docs/fases/fase_4*.md` | Editar/Crear (Cambio 5) |

---

## 6. RIESGOS Y MITIGACIONES
- **`yt.search()` podría requerir PoToken en algún cliente** → los 3 clientes en cascada;
  si los 3 fallan → `notFound` → skip limpio (no audio falso). El Cambio 1 queda como red.
- **Latencia extra** (búsqueda + extracción) → solo para pistas sin ID de YouTube; caché
  en memoria en el scorer evita repetir búsqueda por `track.id`.
- **El JS se ejecuta en isolate QuickJS** y no se puede probar sin dispositivo → escribirlo
  siguiendo EXACTAMENTE el patrón de `extractVideo`. Compilar con `flutter analyze` para
  validar Dart; el runtime JS se valida en dispositivo.
- **NO usar** `DartFetchBridge` cambios ni polyfills: la búsqueda reutiliza el `fetch`
  polyfill que ya funciona para `/player`.

---

## 7. ORDEN DE EJECUCIÓN RECOMENDADO
1. Cambio 1 (A) — rápido, desbloquea el bug crítico aunque B2 falle.
2. Cambio 2a + 2d (modelo + scorer) — Dart puro, testeable sin red.
3. Cambio 4 (tests del scorer) — validar 2d antes de seguir.
4. Cambio 2b + 2c (JS + canal isolate).
5. Cambio 2e (integración en `_processExtraction`).
6. Cambio 3 (controlador + service + eliminar archivo viejo).
7. `flutter analyze` + `flutter test` (excluyendo integration).
8. Cambio 5 (docs).

---

## 8. NOTAS PARA EL AGENTE QUE RECIBE
- El usuario habla español; responder en español.
- **No re-investigues el bundle JS**: la sección 3 ya tiene toda la evidencia (offsets y
  firmas verificadas). Eso fue lo más caro del agente anterior.
- Si `v.author` o `v.duration` son undefined en algún resultado, el código JS ya los
  protege con optional chaining — mantener esa defensa.
- El usuario quiere **robustez** por encima de rapidez: si hay duda entre una opción
  frágil y una robusta, elegir la robusta.
- Si surgen dudas de decisión real (no técnicas), usar `AskUserQuestion`. El usuario
  prefiere ser consultado antes de que se asuman decisiones importantes.
