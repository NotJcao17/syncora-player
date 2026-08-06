# HANDOFF (BRANCH EXPERIMENTAL): Fix fallback de 6 min + robustecer YtMatcher scraper (A + B1)

> **Contexto:** este es un plan **alternativo** al de `docs/handoff_fallback_yt_matcher.md`
> (que es A + B2 / Innertube search). Aquí se mantiene la arquitectura vieja (scraping HTML
> en el Main Isolate) y solo se **robustece** el scraper para que no caiga en el 1/10 de
> fallos. Es para probar en una **branch aparte** y comparar.
>
> **Para el agente que recibe esto:** documento autocontenido. La sección de "EL PROBLEMA"
> es idéntica a la del handoff B2; la diferencia está en la **solución** (sección 3+).

---

## 1. EL PROBLEMA (resumen — ver B2 doc para detalle completo)

### Síntoma
Algunas canciones suenan como un MP3 de SoundHelix de ~6 min en vez de la canción real.

### Causa raíz (cadena)
1. Pista de Deezer → `id` numérico, `track.youtubeVideoId` null.
2. `playCurrent()` (`lib/features/player/syncora_player_controller.dart:286`) llama a `YtMatcherService`.
3. `YtMatcherService` hace GET a `youtube.com/results` con un Dio **mal configurado** →
   YouTube redirige al muro de consentimiento (`consent.google.com`) que rebota sin fin →
   `RedirectException` ("Redirect loop detected" / "Redirect limit exceeded") → devuelve `null`.
4. El ID numérico llega al isolate.
5. **`lib/core/extraction/extraction_isolate.dart:282-292`** devuelve el MP3 de SoundHelix
   como `ExtractionSuccess` → suena el audio de 6 min.

### Comportamiento real
El scraper funciona ~90% de las veces; falla ~10% de forma **intermitente** (YouTube sirve
el consentimiento según IP/carga). El motor de extracción JS **funciona y no se toca**.

### Por qué el Dio actual falla (`lib/core/extraction/yt_matcher_service.dart:10-22`)
```dart
Dio(BaseOptions(
  connectTimeout: ..., receiveTimeout: ...,
  headers: { 'User-Agent': '...', 'Accept-Language': '...' },
))   // ← sin followRedirects explícito, sin validateStatus, sin maxRedirects,
     //   y CRÍTICO: sin persistencia de cookies (=> no sobrevive al consentimiento)
```
El muro de consentimiento es **determinista por sesión/IP**: sin cookies, la 2ª petición
recibe el mismo redirect que la 1ª. Por eso un retry "a lo tonto" no sirve — hay que
**persistir la cookie CONSENT**.

---

## 2. LA SOLUCIÓN (A + B1)

- **Frente A — Quitar el fallback silencioso** (igual que en B2). Obligatorio.
- **Frente B1 — Robustecer el scraper `YtMatcherService`** para que resuelva el ~10% que
  hoy falla, **manteniendo** el scraping HTML en el Main Isolate (sin tocar el isolate JS).
- **No** se migra nada al isolate QuickJS. **No** se toca `extractVideo` ni el motor JS.

La clave de B1: el fallo es por **falta de cookies**, no por "falta de intentos". Así que
el núcleo es (a) persistir cookies para saltar el consentimiento + (b) retry por si acaso.

---

## 3. PLAN DE IMPLEMENTACIÓN

### Cambio 1 — Frente A: quitar fallback silencioso
**`lib/core/extraction/extraction_isolate.dart:282-292`** — reemplazar el bloque que
devuelve el MP3 de SoundHelix por:
```dart
final is11CharYtId = RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(videoId);
if (!is11CharYtId) {
  sendLog('[IsolateJS] ID "$videoId" no es un ID de YouTube válido.');
  return ExtractionFailure(
    requestId: request.requestId,
    error: ExtractionError.notFound,
    message: 'No se pudo resolver un ID de YouTube para "$videoId".',
  );
}
```
> Esto enruta por `_handleExtractionError` → auto-skip limpio en vez de audio falso.
> Con B1 bien hecho, el matcher debería resolver antes de llegar aquí; este bloque queda
> como red de seguridad defensiva.

### Cambio 2 — Frente B1: robustecer `YtMatcherService`

Archivo único: **`lib/core/extraction/yt_matcher_service.dart`**. Reescribir su Dio + lógica.

#### 2a. Reconfigurar Dio (BaseOptions)
```dart
_dio = dio ??
    Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        followRedirects: true,
        maxRedirects: 10,                 // subir del default 5
        validateStatus: (s) => s != null && s < 600,  // no lanzar en 3xx/4xx/5xx
        headers: const {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept-Language': 'en-US,en;q=0.9',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ),
    );
```

#### 2b. Persistencia de cookies (¡el núcleo del fix!)
**Reusar el patrón que YA existe en `DartFetchBridge` (`lib/core/extraction/dart_fetch_bridge.dart:44-67`)**:
un `InterceptorsWrapper` que captura `set-cookie` en cada respuesta y lo reinyecta en cada
petición. NO hace falta añadir el paquete `dio_cookie_manager`.

```dart
final Map<String, String> _cookies = {};

_dio.interceptors.add(
  InterceptorsWrapper(
    onRequest: (options, handler) {
      // 1) Pre-sembrar la cookie CONSENT para saltar el muro de consentimiento
      //    (truco estándar de scrapers de YouTube; evita el redirect a consent.google.com)
      _cookies.putIfAbsent('CONSENT', () => 'YES+cb.20210331-17-p0.en+FX+');
      if (_cookies.isNotEmpty) {
        options.headers['cookie'] =
            _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
      }
      handler.next(options);
    },
    onResponse: (response, handler) {
      // 2) Capturar cualquier set-cookie (incluida la de consent.google.com) y persistirla
      final setCookieHeaders = response.headers['set-cookie'];
      if (setCookieHeaders != null) {
        for (final header in setCookieHeaders) {
          final parts = header.split(';')[0].split('=');
          if (parts.length >= 2) {
            _cookies[parts[0].trim()] = parts.sublist(1).join('=').trim();
          }
        }
      }
      handler.next(response);
    },
  ),
);
```
> **Nota sobre la cookie CONSENT:** el valor `YES+cb.20210331-17-p0.en+FX+` es un valor
> usado ampliamente por scrapers; si en device no funcionara, alternativas: `PENDING+987`,
> `YES+`. La captura de `set-cookie` es el respaldo: aunque el pre-seed falle, tras el
> primer redirect consent.google.com seteará la cookie real y se persistirá para las
> siguientes peticiones. Verificar en device cuál surge efecto.

#### 2c. Retry con backoff ante fallos transitorios
Envolver la petición en un bucle de reintentos. Importante: distinguir
- **"no match encontrado"** (la petición HTTP fue OK pero el regex no halló ID) → **no**
  reintentar (no es transitorio): devolver null.
- **excepción de red/redirect** (DioException/RedirectException) → reintentar con backoff.

```dart
Future<String?> _searchOnce(String query) async {
  final response = await _dio.get<String>(
    'https://www.youtube.com/results',
    queryParameters: {'search_query': query},
  );
  if (response.data == null) return null;
  final matches = RegExp(r'"videoId":"([a-zA-Z0-9_-]{11})"').allMatches(response.data!);
  final seen = <String>{};
  for (final m in matches) {
    final id = m.group(1);
    if (id != null && id.length == 11 && seen.add(id)) return id; // primer ID único
  }
  return null;
}

Future<String?> _searchWithRetry(String query, {int maxAttempts = 3}) async {
  for (int attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await _searchOnce(query);
    } on DioException catch (e) {
      if (kDebugMode) {
        print('[YtMatcher] Intento $attempt/$maxAttempts falló: ${e.type} ${e.message}');
      }
      if (attempt == maxAttempts) return null;
      await Future.delayed(Duration(seconds: attempt * 2)); // backoff 2s, 4s
    }
  }
  return null;
}
```

#### 2d. Mantener la heurística de query actual
Conservar `'${track.artist} ${track.title} official audio'` (línea 51 actual). No cambia.

#### 2e. Pequeña mejora de robustez del parseo (opcional pero recomendado)
El HTML de `/results` trae un blob JSON (`ytInitialData`). El regex actual coge el **primer**
`"videoId"` que puede ser de un canal/playlist sugerido. Para reducir falsos positivos:
- Iterar y saltar IDs que pertenezcan a canales (no es trivial sin parsear más).
- Como mínimo, **deduplicar** (el `seen.add(id)` de 2c ya lo hace).
- Si quieres ir más lejos (B1+), parsear `ytInitialData` para extraer lista de
  `{videoId, title, lengthText, ownerText}` y aplicar el scorer de `YtSearchMatcher`
  (ver handoff B2, sección "Cambio 2d"). Pero para esta branch experimental, mantenerlo
  simple (dedup + primer ID) es suficiente para validar si el fix de cookies resuelve el 1/10.

### Cambio 3 — Tests + docs
- **Test del interceptor de cookies**: como `DartFetchBridge` ya tiene tests
  (`test/core/extraction/dart_fetch_bridge_test.dart`), crear un test análogo que verifique
  que tras un redirect 302 con `set-cookie`, la cookie se persiste y se reenvía en la
  siguiente petición. Usar `dio` con un `MockAdapter` o `http_mock_adapter`.
- No hay tests de `YtMatcherService` hoy; este sería el primero.
- Documentar en `docs/investigacion_y_pitfalls.md` el pitfall del muro de consentimiento y
  la solución (cookie CONSENT + persistencia).

---

## 4. ARCHIVOS AFECTADOS

| Archivo | Acción |
|---|---|
| `lib/core/extraction/extraction_isolate.dart` | Editar (Cambio 1) |
| `lib/core/extraction/yt_matcher_service.dart` | Reescribir Dio + cookies + retry (Cambio 2) |
| `test/core/extraction/yt_matcher_service_test.dart` | Crear (Cambio 3) |
| `docs/investigacion_y_pitfalls.md` | Editar (Cambio 3) |

Mucho más acotado que B2: **2 archivos editados + 1 creado**. No se toca el isolate JS, ni
el bundle, ni el controlador (el contrato `findYoutubeVideoId(track)` se mantiene).

---

## 5. RIESGOS Y MITIGACIONES
- **La cookie CONSENT puede cambiar de formato** → la captura de `set-cookie` es el respaldo
  real; el pre-seed es solo optimización. Probar en device.
- **Bucles de redirect reales (A→B→A)** no se arreglan subiendo `maxRedirects`; se arreglan
  con la cookie (que rompe el bucle al saltarse el consentimiento). Si aun así hay loop,
  el retry aportará poco — ahí se confirma que B1 es frágil y B2 es mejor (conclusión que
  esta branch experimental debe revelar).
- **Scraping HTML es frágil a futuro** (cambios de marcado) → conocido; es la razón de ser
  de la branch: validar si B1 "aguanta" en la práctica.
- **No añadir dependencias**: usar el interceptor manual como `DartFetchBridge`.

---

## 6. ORDEN DE EJECUCIÓN
1. Crear branch experimental (`git checkout -b fix/fallback-b1-scraper`).
2. Cambio 1 (A) — quitar fallback.
3. Cambio 2 (B1) — reescribir `YtMatcherService`.
4. `flutter analyze`.
5. Cambio 3 (test de cookies).
6. `flutter test` (excluyendo integration).
7. **Validación en device**: reproducir varias pistas de Deezer (especialmente las que
   antes caían en el fallback) y observar si ya resuelven. Comparar con la branch B2.
8. Docs.

---

## 7. NOTAS PARA EL AGENTE
- El usuario habla español; responder en español.
- Esta es una **branch experimental** para comparar contra B2. Mantener el scope acotado
  (no migrar al isolate).
- El patrón de cookies **ya existe** en `DartFetchBridge:44-67` — replicarlo, no inventarlo.
- El usuario quiere ver si esto resuelve el 1/10 en la práctica. Si tras implementarlo el
  fallo persiste, **eso es información válida** (significa que B1 no es suficiente y gana B2).
