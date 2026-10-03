# Plan de la Fase 8

**Fecha:** 2026-10-02
**Estado:** plan propuesto, pendiente de decisiones del usuario (ver §6).

Fuente del alcance: `Documento_Maestro.md` §11. Antes de planear se revisó cada punto contra el
código real, no solo contra el documento.

---

## 1. Estado real del alcance (verificado en código)

| Punto de §11 | Estado real | Qué falta |
| :--- | :--- | :--- |
| Sistema OTA del motor de extracción | **No existe.** `JsBundleLoader` lee `assets/js/youtubei.bundle.js` con `rootBundle` y nada más. | Todo (§2–§4). |
| Manejo de fallos de `youtubei.js` | **Débil** (ver §2.2). | Detección de "motor roto" y mensajes propios (8.A). |
| Carpetas para playlists | **No existe.** Ni tabla `folders` ni código. | Todo (8.E). |
| Búsqueda por género | **Ya hecha** en el rediseño de Inicio y Explorar (`docs/fases/inicio_y_explorar.md`): las 27 tarjetas reales de `/genre` en Búsqueda abren `/genre/:id` con pistas, álbumes, artistas, playlists y radios del género. §11 quedó desactualizado. | Nada. Solo corregir §11. |
| Lanzamientos de artistas escuchados | **Ya hecho**: `newReleasesFromArtistsProvider` (Inicio, "Novedades de tus artistas"), filtrando `/artist/{id}/albums` de tus artistas por fecha. El chart global solo queda de respaldo. | Nada. Solo corregir §11. |
| Previews de Deezer (30 s) | `previewUrl` se parsea y no se usa en ningún sitio. | Reproductor de previews y UI (8.F). |

---

## 2. Cómo está hoy el motor (lo que el OTA tiene que respetar)

### 2.1 Qué es "el motor"

El JS que corre en QuickJS dentro del isolate de extracción son **tres piezas concatenadas**:

1. **Polyfills** (`TextEncoder`, `URL`, `fetch` → `dartFetch`, `setTimeout`…): hoy, un string de Dart
   dentro de `js_bundle_loader.dart`.
2. **`youtubei.js` 17.2.0** compilado para navegador (`assets/js/youtubei.bundle.js`, 1.6 MB).
3. **Pegamento** (`extractVideo`, `searchVideos`, elección de formato y bitrate, User-Agent de cada
   cliente, búsqueda en YouTube Music): otro string de Dart en el mismo archivo.

Las piezas 1 y 3 viven en Dart, así que **hoy ni siquiera un OTA del archivo `.js` arreglaría** un
cambio en el User-Agent (`com.google.android.youtube/19.29.37`, que YouTube puede dejar de aceptar)
o en la elección de formatos. Y la jerarquía de clientes (`['ANDROID', 'ANDROID_VR', 'WEB']`) está
hardcodeada en `extraction_isolate.dart`. Para que el OTA sirva, **las tres piezas y la jerarquía
de clientes tienen que viajar juntas en el paquete OTA**.

### 2.2 Qué pasa hoy cuando `youtubei.js` falla

- **Si el bundle no compila en QuickJS**, el isolate solo escribe un log y sigue. Cada extracción
  posterior falla con `extractVideo is not defined` → `unknownError` → auto-skip. Tras 3 pistas
  saltadas, el guard de cascada pausa con *"Varias canciones seguidas no están disponibles"*.
  El mensaje culpa a las canciones cuando el roto es el motor, y esas 3 pistas quedan marcadas en
  gris como "no disponibles" el resto de la sesión.
- **Si YouTube cambia algo** (lo más probable), pasa exactamente lo mismo: todas las pistas
  fallan con `Streaming data not available` (→ `notFound`) o con un `TypeError` del parser
  (→ `unknownError`), y el usuario ve el mismo mensaje engañoso.
- **Si el isolate muere** (excepción no capturada), `ExtractionIsolate` no se entera: no escucha
  `onExit`/`onError`, y los `Completer` pendientes no se completan nunca. La canción se queda
  "cargando" para siempre.

---

## 3. Diseño del OTA (respuestas a las preguntas del usuario)

### 3.1 ¿De dónde sale el motor y quién lo publica? (corregido tras la conversación del 2026-10-02)

Hay **dos saltos**, y los dos son automáticos:

1. **`youtubei.js` (npm) → nuestro repo.** Un workflow programado de GitHub Actions revisa cada 6 h
   si `youtubei.js` publicó versión nueva. Si la hay, la deja en cuarentena 24 h (si un paquete de
   npm sale comprometido, casi siempre se retira en horas) y luego construye el motor (youtubei.js
   nuevo + nuestros polyfills + nuestro pegamento), lo prueba en un QuickJS real, lo firma y lo
   sube a GitHub Releases. También se dispara solo cuando se commitea un cambio en `engine/`.
2. **Nuestro repo → las apps.** Cada app revisa el manifiesto, baja el motor nuevo en segundo plano
   y lo **guarda sin usarlo**. Solo lo activa si el motor que tiene **deja de funcionar**; si el
   nuevo funciona se queda, y si no, vuelve al anterior.

Por qué la app no baja directamente de `youtubei.js`:

- **No se puede ejecutar tal cual.** `youtubei.js` se publica como paquete de npm (módulos ES para
  Node/Deno/navegador). Hay que empaquetarlo con esbuild y pegarle polyfills y nuestro pegamento,
  y eso no se puede hacer dentro del teléfono.
- **Seguridad.** Bajar código de un tercero sin firma significa que, si comprometen su cuenta de
  npm, todos los usuarios ejecutan lo que el atacante quiera. Nuestra firma garantiza que lo que
  corre salió de nuestro pipeline y pasó nuestras pruebas.
- **Compatibilidad.** No toda versión nueva de `youtubei.js` es un arreglo: algunas cambian la API
  que usa nuestro pegamento, o usan sintaxis que QuickJS no soporta. Las pruebas del pipeline y la
  reversión en la app existen para eso.
- **Algunos arreglos son nuestros, no de ellos.** El User-Agent, la jerarquía de clientes y la
  elección de formatos viven en nuestro pegamento: `youtubei.js` no puede arreglarlos. Ese cambio sí
  necesita un commit, pero publicarlo es automático.

El código Dart/Flutter (pantallas, reproductor, base de datos) **nunca** viaja por OTA: Flutter lo
compila a código nativo, y cambiarlo sigue requiriendo un APK/EXE nuevo. Esto es una ventaja, no
una limitación: el OTA solo puede tocar la pieza que YouTube rompe, nada más.

**Límites honestos de la automatización:** (1) entre que YouTube rompe algo y `youtubei.js` publica
el arreglo no hay nada automático que hacer (las descargas offline siguen sonando); (2) cambios que
requieren tocar Dart (un puente nuevo, headers de ExoPlayer) necesitan APK/EXE nuevo; (3) bloqueos
tipo PoToken/BotGuard que exigen un navegador real no los arregla ninguna librería en QuickJS.

### 3.2 ¿Se descarga completo o solo la diferencia?

**Completo, pero comprimido**: el motor pesa ~1.6 MB y con gzip **~260 KB** (medido). Un parche
binario (bsdiff) ahorraría ~200 KB unas pocas veces al año a cambio de un modo de fallo nuevo: si el
parche se aplica sobre una base distinta a la esperada, sale un motor corrupto. No compensa.

La comprobación periódica es un archivo de **~1 KB** (el manifiesto); el motor completo solo se
baja cuando el manifiesto anuncia una versión más nueva.

### 3.3 ¿Cómo y cuándo se descarga?

- **Comprobación normal:** 15 s después de abrir la app (sin bloquear el arranque), como máximo una
  vez cada 12 h.
- **Comprobación de emergencia:** cuando el detector de 8.A decide que el motor está roto (varias
  pistas distintas fallando seguidas sin un solo éxito, con internet). Como máximo una cada 30 min.
- **Descarga:** en segundo plano con `dio`, a un archivo temporal. Ignora el ajuste "descargar solo
  con WiFi": son ~260 KB y sin motor no suena nada.
- **Cuándo se aplica:**
  - Si el motor actual funciona: **nunca**. El nuevo queda guardado, listo para cuando haga falta.
    Un motor que funciona no se cambia por uno que nadie ha probado en un teléfono real.
  - Si el motor actual está roto: **en caliente**, en cuanto no haya ninguna extracción en curso, y
    se reintenta la canción que falló.
  - Excepción opcional: al lanzar el workflow a mano se puede marcar "aplicar a todos", y las apps lo
    activan en el siguiente arranque aunque el suyo funcione (para un arreglo propio ya probado).

### 3.4 ¿Una descarga nos puede romper algo?

Capas de protección, en el orden en que actúan:

1. **Firma Ed25519.** El manifiesto va firmado en CI con una llave privada que solo existe en los
   secretos de GitHub; la app lleva la llave pública. El manifiesto incluye el SHA-256 del motor,
   así que una firma cubre todo. Si alguien compromete el servidor de descarga, no puede servir un
   motor que la app acepte.
2. **Compatibilidad declarada.** El manifiesto dice qué versión del *contrato* Dart↔JS usa
   (`engineApi`). Si un motor futuro necesita algo nuevo del lado de Dart (ej. un puente nuevo), sube
   a `engineApi: 2` y las apps viejas **simplemente no lo descargan**: se quedan con el último motor
   compatible.
3. **Nunca hacia atrás.** Solo se instala un motor con número de build mayor que el activo. Nadie
   puede forzar a la app a volver a un motor viejo reenviando un manifiesto antiguo (firmado pero
   obsoleto).
4. **Escritura atómica.** Se baja a `.tmp`, se descomprime, se verifica el SHA-256 y solo entonces
   se renombra. Un corte de red o de batería a mitad nunca deja un motor a medias.
5. **Prueba de carga antes de confiar en él.** Al arrancar con un motor nuevo, el isolate lo evalúa
   y comprueba que expone el contrato (`extractVideo`, `searchVideos`, metadatos). Si falla, la app
   **vuelve sola** al motor anterior y pone esa versión en lista negra para no volver a bajarla.
6. **Periodo de prueba.** Un motor recién instalado está "a prueba" hasta su primera extracción
   exitosa. Si en ese periodo falla con errores de *código* (`TypeError`, `ReferenceError`,
   `is not a function` — errores del propio motor, no de YouTube), se revierte igual que en el
   punto 5.
7. **Revocación remota.** El manifiesto puede listar versiones revocadas: si publicas un motor malo
   que pasó todas las pruebas, publicas otro que lo revoque y las apps lo descartan.
8. **El motor de fábrica nunca se borra.** El que viene dentro del APK/EXE siempre está como
   último recurso. Y si una actualización de la app trae un motor de fábrica más nuevo que el
   descargado, gana el de fábrica.

**Qué no puede tocar el OTA aunque todo lo anterior fallara:** el motor corre dentro de QuickJS sin
acceso a archivos, base de datos, ajustes, descargas ni Supabase. Sus únicas salidas son el puente
`dartFetch` (peticiones HTTP) y devolver una URL de audio. El peor caso realista es "no suena", y
para eso están los puntos 5–8.

### 3.5 Dónde se aloja (decidido: GitHub Releases)

**GitHub Releases** del repo (público), en una release fija `engine-channel`
marcada como *prerelease* para que nunca se confunda con una release de la app:

- `https://github.com/NotJcao17/syncora-player/releases/download/engine-channel/engine-manifest.json`
- `.../engine-channel/engine-<build>.js.gz` (inmutable, un archivo por versión)

Gratis, sin consumir el egress de Supabase (5 GB/mes, que los usuarios sin cuenta —ilimitados— se
comerían rápido con cada actualización), y el workflow sube con el `GITHUB_TOKEN` propio de Actions:
**el único secreto nuevo es la llave de firma**. El Documento Maestro decía Supabase Storage; esto
se desvía, por eso se pregunta.

---

## 4. Bundles de implementación

Orden estricto: 8.A → 8.B → 8.C → 8.D, luego 8.E y 8.F (independientes del OTA). Gate de cada
bundle: `flutter analyze` limpio + un `flutter test` completo antes de comitear.

### 8.A — Robustez del motor y mensajes (sin OTA todavía)

- [ ] `ExtractionIsolate`: escuchar `onExit`/`onError`; si el isolate muere, completar los
      pendientes con error de red y volver a lanzarlo en la siguiente petición.
- [ ] El isolate informa al arrancar si el motor cargó (`EngineReady` / `EngineLoadFailed`) en vez
      de solo escribir un log.
- [ ] `EngineHealthMonitor` (lógica pura, testeable): decide "motor roto" con fallos seguidos en
      pistas **distintas**, sin éxitos, con internet; distingue errores de código del motor.
- [ ] Con el motor roto: pausa con un aviso propio (*"El motor de YouTube dejó de funcionar.
      Buscando una actualización…"*), **sin** marcar las pistas como no disponibles, y sin seguir
      saltando.
- [ ] Configuración → sección "Motor de reproducción": versión activa, origen (de fábrica / OTA),
      última comprobación, botón "Buscar actualización".

### 8.B — Empaquetado del motor (refactor sin cambio de comportamiento)

- [ ] Carpeta `engine/`: `src/polyfills.js` y `src/glue.js` (sacados **tal cual** de los strings de
      Dart), `vendor/youtubei.bundle.js` (el mismo archivo de hoy, sin recompilar), `build.mjs`.
- [ ] El pegamento expone `globalThis.SYNCORA_ENGINE = {api, build, clients}`; Dart lee de ahí la
      jerarquía de clientes (con la de hoy como respaldo).
- [ ] `build.mjs` genera `assets/js/syncora_engine.js` + `assets/js/syncora_engine.json` (build,
      api, sha256). `JsBundleLoader` carga ese archivo completo.
- [ ] Comprobación en CI/local: el motor generado se evalúa en un QuickJS real
      (`quickjs-emscripten`) y expone el contrato.
- [ ] Script para actualizar `youtubei.js` a propósito (`npm run update-lib`), nunca automático.

### 8.C — Cliente OTA en la app

- [ ] `EngineManifest` + verificación Ed25519 (paquete `cryptography`, Dart puro).
- [ ] `EngineUpdateService`: comprobación normal y de emergencia, descarga, gzip, SHA-256,
      instalación atómica, lista negra, revocación.
- [ ] `EngineBundleStore`: elige qué motor arrancar (descargado compatible y más nuevo, o el de
      fábrica) y registra el resultado de la prueba de carga.
- [ ] Recarga en caliente del isolate solo en emergencia y sin extracciones en curso.
- [ ] Tests: firma válida/alterada, `engineApi` incompatible, versión menor, revocación, corte a
      mitad de descarga, fallo de carga → reversión.

### 8.D — Pipeline de publicación

- [ ] `tool/engine/keygen.mjs`: genera el par de llaves; escribe la privada en un archivo ignorado
      por Git y la pública directamente en el código Dart.
- [ ] `tool/engine/sign.mjs`: arma y firma el manifiesto.
- [ ] `.github/workflows/publish-engine.yml` con tres disparadores: programado cada 6 h (versión
      nueva de `youtubei.js` en npm, tras 24 h de cuarentena), push a `master` que toque `engine/`,
      y manual (con la opción "aplicar a todos"). Construye, prueba en QuickJS, firma y sube a la
      release `engine-channel`; borra los motores viejos para no pasar de 1000 archivos.
- [ ] Pasos manuales para ti, **una sola vez** (documentados): correr `keygen` y pegar la llave
      privada como secreto `ENGINE_SIGNING_KEY` en GitHub. Después no hay pasos manuales.

### 8.E — Carpetas para playlists

- [ ] Migración 20: tabla `folders` (RLS solo dueño) y `playlists.folder_id` (`ON DELETE SET NULL`:
      borrar una carpeta nunca borra sus playlists).
- [ ] Drift v13: tabla `Folders` y `Playlists.folderId`.
- [ ] Sync de carpetas antes que el de playlists; toda escritura por un servicio que persiste en
      ambos lados (Pitfall #28). En modo local, solo Drift.
- [ ] Biblioteca: carpetas como elementos de la lista, vista de carpeta, crear/renombrar/borrar,
      "Mover a carpeta" en el menú de 3 puntos. Diálogos centrados en PC, hojas en móvil.
- [ ] "Tus me gusta" y "On Repeat" no entran en carpetas.

### 8.F — Previews de Deezer (30 s)

- [ ] `PreviewPlayer`: motor de audio propio (no toca la cola ni el historial ni las
      estadísticas), pausa la reproducción principal mientras suena y la puede reanudar al terminar.
      Pide `/track/{id}` justo antes de sonar, porque las URLs de preview caducan.
- [ ] UI según la decisión de §6.

### 8.G — Cierre

- [ ] `docs/fases/fase_8.md`, §11 del Documento Maestro corregido, filas nuevas en
      `docs/matriz_de_pruebas.md`, estado en `CLAUDE.md`.

---

## 5. Hallazgos verificados al planear

- **H-8-1:** "Búsqueda por género" y "Lanzamientos de artistas escuchados" de §11 ya estaban
  implementados (rediseño de Inicio y Explorar, 2026-09-17). §11 se escribió antes.
- **H-8-2:** el polyfill y el pegamento del motor viven en Dart, no en el `.js` — un OTA solo del
  archivo `youtubei.bundle.js` no habría podido arreglar el User-Agent ni la elección de formatos.
- **H-8-3:** si el isolate de extracción muere, las peticiones pendientes no se completan nunca
  (sin `onExit`).
- **H-8-4:** un motor roto se presenta como "canciones no disponibles" y deja esas pistas en gris
  toda la sesión.

---

## 6. Decisiones del usuario

1. Dónde alojar el OTA — **GitHub Releases** (sin límite de ancho de banda, todos reciben OTA con o
   sin cuenta, no comparte cupo con Supabase ni con el Worker de imágenes).
2. Motores de respaldo si `youtubei.js` cae — **no por ahora**: detección, mensajes claros y OTA de
   emergencia. Las descargas offline siguen sonando.
3. Previews — **solo un feed "Descubrir"**: tarjetas con preview automático de 30 s (me gusta /
   agregar / siguiente) con canciones de artistas parecidos que el usuario no ha escuchado. Sin
   acción "vista previa" en los menús.
4. Carpetas — **un solo nivel** (carpetas que contienen playlists, sin carpetas anidadas).
