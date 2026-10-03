# Fase 8 — OTA del motor, manejo de fallos, carpetas y Descubrir

**Fecha:** 2026-10-02
**Estado:** implementada y pusheada a `master`. `flutter analyze` limpio, 715 tests en verde.
Pendiente: los pasos manuales de §6 y las pruebas en dispositivo de `docs/matriz_de_pruebas.md`
(sección "Fase 8").

Plan, decisiones del usuario y razonamiento completo del diseño: `docs/plan_fase_8.md`. Este
documento resume lo construido y lo que **no conviene revertir**.

---

## 1. Alcance real

| Punto de §11 del Documento Maestro | Resultado |
| :--- | :--- |
| OTA del motor de extracción | Hecho (8.B, 8.C, 8.D) |
| Manejo de fallos de `youtubei.js` | Hecho (8.A) |
| Carpetas para playlists | Hecho, un solo nivel (8.E) |
| Previews de Deezer (30 s) | Hecho como feed "Descubrir" (8.F) |
| Búsqueda por género | Ya existía (rediseño de Inicio y Explorar) |
| Lanzamientos de artistas escuchados | Ya existía (`newReleasesFromArtistsProvider`) |

Decisiones del usuario: hosting en **GitHub Releases**; **sin motores de respaldo** (yt-dlp/Piped)
por ahora; previews **solo como feed Descubrir**; carpetas de **un nivel**; cuarentena de **24 h**
para versiones nuevas de `youtubei.js`; opción **"aplicar a todos"** en el workflow manual.

---

## 2. El motor y su empaquetado (8.B)

El JS que corre en QuickJS es `polyfills + youtubei.js + pegamento + SYNCORA_ENGINE`. Hasta esta
fase, polyfills y pegamento eran strings de Dart (H-8-2): un OTA solo de `youtubei.bundle.js` no
habría podido arreglar el User-Agent, la elección de formatos ni la jerarquía de clientes. Ahora:

- `engine/src/polyfills.js`, `engine/src/glue.js`: sacados tal cual de Dart.
- `engine/vendor/youtubei.bundle.js` (+ `youtubei.version`): el mismo archivo de antes (17.2.0).
  `npm run update-lib -- <versión>` lo recompila desde npm (esbuild, IIFE `YouTubeJS`, ES2019).
- `engine/engine.config.json`: `api` (contrato con Dart) y `clients` (antes hardcodeada en
  `extraction_isolate.dart`; ahora viaja dentro del motor y se cambia por OTA).
- `engine/scripts/build.mjs` → `assets/js/syncora_engine.js` + `.json` (build, api, sha256). Es el
  motor de fábrica y el mismo formato que se publica por OTA.
- `.gitattributes` fija esos archivos como binarios: su SHA-256 vive en la ficha `.json`, y la
  conversión de saltos de línea de Git en Windows lo rompería.

Verificado: el motor reempaquetado carga en QuickJS real (`quickjs-emscripten`) y **extrae 3/3**
canciones en vivo desde IP residencial (`npm run live`). La 18.1.0 de npm también: el camino
automático funciona con la versión más nueva real.

## 3. Manejo de fallos del motor (8.A)

- **El isolate informa si el motor cargó** (`EngineLoadReport`): compila, expone `extractVideo` /
  `searchVideos` y declara un `api` que esta app entiende. Antes solo dejaba un log.
- **El isolate ya no puede morir en silencio** (H-8-3): `onExit` completa lo pendiente con error de
  red (el reproductor reintenta 1 vez) y la siguiente petición lo vuelve a arrancar.
- **`suspectEngine`** en `ExtractionFailure`: lo marca solo el isolate cuando YouTube contestó y
  aun así el motor no pudo usar la respuesta (vídeo encontrado sin streams en ningún cliente,
  excepción del parser, búsquedas que revientan, motor que no cargó). "No hay coincidencia" de
  catálogo y vídeos privados/borrados **no** lo llevan.
- **`EngineHealthMonitor`**: 2 fallos sospechosos en pistas distintas, sin un éxito entre medio →
  motor roto. El `EngineManager` convierte ese fallo en `ExtractionError.engineBroken`.
- **Reproductor**: ante `engineBroken` pausa sin saltar, **quita la marca de "no disponible"** a las
  pistas de la racha (H-8-4: antes un motor roto dejaba canciones en gris toda la sesión) y avisa
  *"YouTube cambió algo y el motor dejó de funcionar. Buscando un arreglo…"*. Si el `EngineManager`
  se recupera, reintenta la misma pista sola; si no, avisa que no hay arreglo todavía (con
  "Reintentar").
- **Bloqueo de IP** ("Sign in to confirm you're not a bot"): el pegamento ahora conserva el
  `playabilityStatus` de YouTube en el error, y la app lo trata como un 403 (pausa, sin saltar la
  cola; Pitfall #14) en vez de "canción no disponible". La restricción de edad sigue siendo de la
  canción.
- **Configuración → Motor de reproducción**: versión, origen (de fábrica / actualización),
  `youtubei.js`, estado, última comprobación, motor guardado "por si falla", botón "Buscar
  actualización" y "Usarla al reiniciar".

## 4. OTA (8.C cliente, 8.D publicación)

### Cliente (`lib/core/extraction/engine/`)

| Pieza | Qué hace |
| :--- | :--- |
| `engine_trust.dart` | Llave pública Ed25519 y URL de la release `engine-channel`. Llave vacía = OTA apagado. |
| `engine_manifest.dart` | Verifica la firma sobre los bytes exactos del payload (sin canonicalizar JSON) y valida el contenido. |
| `engine_updater.dart` | Baja manifiesto y `.js.gz`; descomprime con tope (anti bomba de gzip); comprueba tamaño y SHA-256 firmados. |
| `engine_store.dart` | `state.json` + `engine-<build>.js` en el directorio de soporte. Escritura atómica. `EnginePolicy`: decisiones puras. |
| `engine_manager.dart` | Orquesta: arranque, monitor, recuperación, comprobaciones, revocaciones. |

Reglas que no se deben romper:

1. **Un motor que funciona no se cambia solo.** Lo descargado queda guardado y solo se activa si el
   activo falla, salvo rollout `next_launch` ("aplicar a todos").
2. **El motor activo persistido solo cambia con prueba**: una extracción real exitosa durante la
   recuperación. Probar candidatos no toca el estado.
3. **Nunca hacia atrás**: solo se baja un build mayor que todo lo que ya hay.
4. **El de fábrica gana** si es igual o más nuevo que el descargado (actualizar la app nunca queda
   tapado por un OTA viejo). Nunca se borra.
5. Un motor que **no carga** o que falla con **errores de su propio código** durante una prueba va a
   lista negra. Uno que falla porque YouTube rompió todo no: se queda el más nuevo.
6. Comprobación normal 15 s tras arrancar y como mucho cada 12 h; de emergencia, como mucho cada
   30 min; recuperación completa, como mucho cada 10 min salvo que haya un motor nuevo.

### Publicación (`.github/workflows/`, `engine/scripts/`)

- `publish-engine.yml`: cada 6 h revisa npm (`check-upstream.mjs`, cuarentena 24 h, versiones
  rechazadas en `vendor/rejected-versions.txt`); también en push que toque el motor y a mano.
  Construye → **prueba obligatoria en QuickJS** → prueba en vivo (informativa) → firma → sube
  primero el motor y después el manifiesto → borra motores viejos (quedan 10) → si fue una versión
  nueva de `youtubei.js`, la commitea en `engine/vendor/`. Si una versión nueva no pasa la prueba,
  se anota como rechazada y el workflow falla **una sola vez** (te llega un correo).
- `engine-canary.yml`: diario, prueba el motor **publicado** contra YouTube.
- `sign.mjs`: arma el sobre `{payload, signature}`, conserva el motor más nuevo de otras `api` y la
  lista de revocados, verificando antes la firma del manifiesto anterior.
- `keygen.mjs`: privada a `engine/signing_key.pem` (ignorado por Git), pública directo a
  `engine_trust.dart`. **Ya se corrió**: la llave pública está en el código.

## 5. Carpetas (8.E) y Descubrir (8.F)

**Carpetas.** Migración 20 (`folders`, RLS solo dueño, `playlists.folder_id ON DELETE SET NULL`,
trigger que impide apuntar a una carpeta ajena). Drift v13 (`Folders`, `Playlists.folderId` sin
`references`: la base no activa `PRAGMA foreign_keys`). Toda escritura por `FolderService` (nube
primero; si falla, no se toca Drift — Pitfall #28; "sacar de la carpeta" manda `NULL` explícito —
Pitfall #29). El sync baja carpetas antes que playlists; si no puede leerlas (p. ej. migración 20
sin aplicar) **no toca la carpeta de ninguna playlist**. La migración modo local → cuenta sube las
carpetas después de las playlists, sin duplicar por nombre. "Tus me gusta" y "On Repeat" no entran
en carpetas. Biblioteca: fijadas → carpetas → resto; buscando, lista plana. Barra lateral de PC:
carpetas desplegables (colapsada, lista plana de portadas).

**Descubrir.** Ruta `/discover`, accesos en Inicio (accesos rápidos, ahora 2×2 en móvil y 4 en PC)
y en Búsqueda. Fuente sin IA, **mitad y mitad** (decidido tras las pruebas: solo radio daba casi todo
desconocido): las 2 canciones más populares de hasta 3 artistas **parecidos** a tus más escuchados
(reconocible, un salto) intercaladas con la radio de uno de ellos (descubrimiento, dos saltos), quitando
lo ya escuchado, lo que ya está en "Me gusta", a los propios artistas semilla y con máximo 2 por
artista; sin historial, top global. `PreviewPlayer` es un motor propio (sin crossfade): **no toca
la cola, el historial ni las estadísticas**. Pausa el reproductor principal al sonar y se calla si
el principal se reanuda. Las URLs de preview caducan: se pide la fresca y se reintenta una vez.
"Completa" pone la canción y el resto del feed en la cola principal.

## 6. Pasos manuales pendientes (para el desarrollador humano)

1. ~~Subir la llave de firma a GitHub y lanzar la primera publicación~~ — **hecho el 2026-10-03**:
   secreto `ENGINE_SIGNING_KEY` cargado y motor `202610030222` publicado en `engine-channel`
   (firma y SHA-256 verificados descargándolo desde la URL que usa la app). Falta solo guardar una
   copia de `engine/signing_key.pem` en un gestor de contraseñas (hecho).
2. ~~Aplicar la migración 20~~ — **hecho el 2026-10-03** (`supabase db push --linked`).
3. Pruebas en dispositivo de la Fase 8 (`docs/matriz_de_pruebas.md`).

### Keep-alive (`.github/workflows/keepalive.yml`)

Cada 3 días, sin commits: (1) vuelve a habilitar por la API los workflows programados (incluido él
mismo), porque GitHub los desactiva en repos públicos tras 60 días sin actividad y el bot solo
commitea cuando `youtubei.js` saca versión; (2) hace una lectura mínima con la llave `anon` a
`app_config` (lectura pública, sin datos de usuarios) para que Supabase no pause el proyecto
gratis por 7 días de inactividad. Usa los secretos `SUPABASE_URL` y `SUPABASE_ANON_KEY`
(públicos por diseño, ya cargados). Verificado: corrida exitosa y los 3 workflows en `active`.

## 7. Hallazgos verificados

- **H-8-1:** género y novedades personalizadas de §11 ya estaban hechos (§11 se escribió antes).
- **H-8-2:** polyfills y pegamento vivían en Dart: un OTA solo de `youtubei.bundle.js` no servía.
- **H-8-3:** si el isolate de extracción moría, las peticiones pendientes no completaban nunca.
- **H-8-4:** un motor roto se presentaba como "canciones no disponibles" y las dejaba en gris.
- **H-8-5:** desde servidores de GitHub, YouTube contesta búsquedas pero niega el audio en los tres
  clientes (bloqueo de IPs de datacenter). Como el pegamento resumía todo en "Streaming data not
  available", la prueba en vivo lo leía como "motor roto" y el canario habría mandado una falsa
  alarma diaria. Corregido conservando el `playabilityStatus` en el error.
- **H-8-6:** la barra lateral de PC hacía `ref.watch` dentro del builder de un `StreamBuilder`. Con
  un provider que emite solo (las carpetas) Riverpod leía una suscripción cerrada (lo destapó el
  smoke test). Los `watch` pasaron al nivel del `Consumer`.
- **H-8-7:** Descubrir se quedaba cargando para siempre en PC. Con Riverpod 3, `ref.read(provider.future)`
  sobre un provider que **nadie está escuchando** lo deja en pausa y el future nunca completa. En móvil
  funcionaba por casualidad (algo en pantalla escuchaba "Me gusta"). Se cambió por una consulta directa
  al DAO. **Regla:** no usar `ref.read(x.future)` para datos que se necesitan sí o sí; leer de la fuente o
  usar `ref.watch`/`listen`. Hay un test de widget de Descubrir en tamaño móvil y escritorio como regresión.
- **Ajustes tras las pruebas en dispositivo (2026-10-03):** el "+" de Biblioteca agrupa Playlist, Carpeta y
  Playlist con IA (con tres botones sueltos el título se cortaba en móvil); frases de Descubrir más cortas;
  la fila de acciones de Descubrir se reparte en partes iguales (se desbordaba en móviles angostos); el primer
  lote de Descubrir es más chico para empezar a sonar antes.
- **H-8-8:** en PC las previews tardaban 3–4 s y a veces más de 10. Medido: bajar una preview entera
  (~480 KB) tarda 0.1–0.4 s; lo lento era abrirla en streaming con libmpv. En Windows ahora se descargan
  a archivos temporales (`PreviewFileCache`) y se pre-descargan las 2 siguientes tarjetas; se borran al
  alejarse y al salir de Descubrir. En Android no cambió nada (ExoPlayer ya era rápido).
