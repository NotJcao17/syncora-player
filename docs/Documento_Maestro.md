# Documento Maestro de Planeación y Arquitectura: Syncora Player

**Proyecto:** Syncora Player  
**Repositorio:** `https://github.com/NotJcao17/syncora-player.git`  
**Objetivo:** Reproductor de música nativo (Windows/Android) 100% gratuito, privado, enfocado en resiliencia y diseño premium.

**Nota de escala:** streaming, descargas y uso 100% local/sin cuenta son **ilimitados** para
cualquier usuario. Solo la **cuenta con nube** (sincronización entre dispositivos, funciones de
IA) está limitada a los **primeros 250 registros** — es un proyecto hobby, sin fines de lucro y
sostenido en planes gratuitos (ver §4.5). El tope se puede subir en cualquier momento con un
`UPDATE` en la base de datos, sin redeploy, si el proyecto crece.

---

## 1. Metodología de Trabajo y Delegación

### División de Responsabilidades
*   **El Agente (IA):**
    *   Genera arquitectura, código (Flutter, Dart, SQL) y pruebas automatizadas (unitarias para lógica).
    *   Configura el proyecto, realiza migraciones de BD y escribe documentación técnica.
    *   Ejecuta comandos Git. **Reglas estrictas:** Commits sin descripción, solo mensaje. No usar `Co-authored-by`. Al finalizar y validar cada fase, el Agente realizará `git push` al repositorio remoto.
    *   Actualiza este documento y el plan de implementación. Al finalizar cada fase, el Agente creará un documento de contexto resumido dentro de la carpeta `docs/fases/fase_X.md` registrando todo lo logrado y decisiones de arquitectura de la fase. Asimismo, indicará explícitamente qué pruebas de la `matriz_de_pruebas.md` corresponden ejecutar, guiando al humano sobre cómo realizarlas.
    *   **Pruebas Locales (Ojos de la IA):** Prueba de UI en Chrome con seguridad web desactivada (`flutter run -d chrome --web-browser-flag "--disable-web-security"`). *Nota Técnica:* Para evitar fallos en web (ya que `media_kit` y SQLite son binarios nativos), se implementará un bypass usando `kIsWeb` en la inicialización, cargando bases de datos en memoria (Mocks) solo para validar la interfaz visual sin errores.
*   **El Desarrollador (Humano):**
    *   Prueba el audio y el comportamiento nativo en Windows (máquina de desarrollo) y Android (dispositivo físico conectado por USB con Depuración USB activada).
    *   Crea el proyecto en Supabase, maneja los secretos.
    *   Ejecuta las migraciones de base de datos con el **Supabase CLI** (`supabase db push`) desde su terminal local. El agente genera los archivos `.sql`; el humano los aplica.
    *   Provee validación final de UI/UX.
    *   **Flutter:** Ya instalado y configurado para Windows y Android. `flutter doctor` sin errores críticos.

---

## 2. Requerimientos Funcionales y Pantallas (UI/UX)

### 2.1 Pantallas Móvil
*   **1.1 Inicio:** Playlists/Álbumes recientes. Contenido destacado (nuevos lanzamientos, artistas recomendados, top global/país, estadísticas resumidas).
*   **1.2 Explorar y Buscar:** Buscador universal (Canción, Artista, Álbum, Playlist) con tags indicadores. Si es complejo, buscadores separados por tipo.
*   **1.3 Biblioteca:** Playlists y álbumes guardados. Filtros (playlists, álbumes, descargados). Búsqueda interna. Ordenar por carpetas.
*   **1.4 Reproductor Fullscreen:** Portada, barra de progreso (usando un *waveform* decorativo generado al vuelo para mayor estética), controles (play, pausa, prev, next), aleatorio, dispositivo de salida (si es posible), botón cola, me gusta (checkmark), repetir, menú 3 puntos. Deslizar hacia abajo o botón para letras. Botón minimizar.
    *   *Mini reproductor:* Sobre la barra de navegación, miniatura, nombre, artista, play/pausa. Reproductor en pantalla bloqueada (nombre, artista, foto, controles).
*   **1.5 Cola de Reproducción:** Vista superpuesta. Drag & drop para ordenar, deslizar izquierda para eliminar, deslizar derecha (en listas) para agregar a cola. Botón "Editar" para selección múltiple (eliminar o mover arriba).
    *   **Modelo de cola dual (definido en Fase 7):** una **cola automática** (generada del contexto activo, se regenera al cambiar shuffle↔normal o de playlist) y una **cola manual** (lo que el usuario agrega explícitamente; se reproduce primero, en orden **FIFO**, y **sobrevive** a los cambios de la automática — ni siquiera las funciones de IA la tocan). Las pistas ya reproducidas **se eliminan** de la cola; el botón "anterior" usa una **pila de historial única**, así que al retroceder desde una pista manual se vuelve a esa pista manual (difiere de Spotify a propósito).
*   **1.6 Detalle de Artista:** Info de Deezer, canciones más escuchadas, discografía.
*   **1.7 Playlist/Álbum:** Portada (default: cuadrícula generada automáticamente con las primeras 4 portadas **distintas** de la lista, o color/degradado a elección del usuario), nombre, autor, duración, número de canciones. Botones rápidos: aleatorio, descargar, play, guardar, menú 3 puntos (editar, eliminar, compartir pública/privada, agregar a otra). Lista de pistas con mini menú (3 puntos: agregar a playlist, agregar a cola, descargar pista, ver álbum, ver artista, compartir).
*   **1.8 Estadísticas (Wrapped):** Resumen de uso, top canciones, géneros, artistas, minutos. Tarjetas imprimibles tipo stories.
*   **1.9 Configuración:** Descarga solo con WiFi, visualizador de almacenamiento, borrar caché/descargas, selector de avatar predefinido, temporizador de apagado (sleep timer). Políticas de privacidad y legales.

### 2.2 Pantallas PC (Desktop)
*   **Layout:**
    *   *Izquierda:* Sidebar minimizable con Biblioteca.
    *   *Abajo:* Barra de reproductor constante (portada, info, agregar a playlist, progreso, controles, letras, cola, volumen).
    *   *Derecha:* Sidebar colapsable para la Cola (se activa con botón).
    *   *Centro:* Contenido principal dinámico (Inicio, Búsqueda, etc.).
    *   *Arriba:* Buscador siempre presente, foto de perfil, controles de ventana.

### 2.3 Características Principales (Core)
*   *Prueba de concepto inicial:* Probar reproducción y extracción desde YouTube antes de implementar funciones complejas.
*   Buscador universal e interno en playlists.
*   Menú de 3 puntos ubicuo en elementos de listas.
*   Creación/edición de playlists (almacenando en BD: nombre, desc, portada, fecha agregado, artista, título, duración, álbum para poder ordenar y buscar sin depender de llamadas a API).
*   Modos de reproducción: Normal, Aleatorio, Repetir.
*   **Reproducción fluida:** Soporte para Gapless Playback y Skip Silence (eliminar silencios al principio y final de pistas). En **Android** (`just_audio`): activando el flag `setSkipSilenceEnabled` de ExoPlayer **únicamente para podcasts/spoken-word** (donde hay silencios largos dentro de la pista); para gapless entre canciones se confía en la Playlist API de ExoPlayer. En **Windows** (`media_kit`/libmpv): usando el filtro de ffmpeg `--af=lavfi=[silencedetect=noise=-50dB:duration=0.3]` para detectar los bordes de silencio y ejecutar un seek manual a la primera muestra de audio real. ⚠️ **Nota crítica:** `scaletempo` NO sirve para esto — es un filtro de cambio de velocidad de reproducción (pitch-preserving speed), no de detección de silencio; ver Pitfall #7.
*   Descarga de álbum/playlist (selección de calidad de audio permitida).
*   Playlist "Me gusta" y Modo Offline (Online-first con capacidades offline completas).
*   Fijar (pin) playlists y ordenarlas (incluyendo soporte a carpetas).
*   Lanzamientos nuevos de artistas escuchados.
*   Manejo de errores amigable (canciones no disponibles en gris, modo sin internet, etc.).
*   **Auto-Skip y Protección contra Bucles de 403 (implementada desde Fase 1):** El reproductor intentará reproducir el mejor resultado. Si falla por error lógico (no encontrado), hace Auto-Skip. Si falla por conectividad o por **Error 403 (Baneo/BotGuard)**, se implementará una regla estricta de **Máximo 1 Reintento**. Si el 403 persiste, el reproductor SE PAUSA INMEDIATAMENTE y muestra un error visual, evitando freír la CPU o banear la IP del usuario en un bucle infinito de reintentos rápidos. ⚠️ **Esta lógica se construye en la Fase 1 (Spike Técnico)** junto con el motor de extracción, ya que el escenario de baneo es posible desde el primer `dartFetch` a YouTube; el Auto-Skip "inteligente" completo (UI, cola dinámica) se pule en la Fase 7.
*   **Importación y Exportación de Playlists:** Soporte para importar playlists desde servicios externos usando herramientas de migración (ej. TuneMyMusic, Soundiiz): el usuario exporta su playlist desde Spotify/Apple Music como archivo de texto o CSV, lo carga en Syncora y la app hace la búsqueda automática en Deezer para cada pista, manejando rate limits con una cola progresiva. También se soporta **exportación** de cualquier playlist en formato texto/CSV (título, artista, álbum, duración) para portabilidad total.
*   Evitar podcasts/videos musicales (filtrando búsquedas a música pura).
*   Soporte nativo de controles del SO (Asistente de Google, pantalla de bloqueo): Uso de `audio_service` (Android) y `smtc_windows` (Windows). En Android se configurarán acciones multimedia personalizadas (`MediaControl` / `CustomAction`) para exponer botones como "Me gusta" y "Aleatorio" directamente dentro de la tarjeta de notificación cuando se implemente la UI real y la base de datos (Fases 3 y 4).

### 2.4 Funciones IA y Extras

> Alcance y flujos definitivos definidos en `docs/plan_fase_7.md`. Reglas transversales acordadas:
> toda salida de IA usa **`response_schema` (salida estructurada)**, nunca texto libre parseado a
> mano; **la Edge Function jamás escribe en la BD** (solo devuelve sugerencias, el `INSERT`/`DELETE`
> lo ejecuta el cliente con el JWT del usuario tras una **vista previa confirmada**); y lo que la IA
> sugiere **nunca se guarda tal cual** — se resuelve contra el catálogo de Deezer y solo se persisten
> datos canónicos, así que es imposible ensuciar la BD con un título inventado.

*   Funciones IA (Gemini): Generar playlist por prompt de texto, generar cola de reproducción por prompt de texto, modificar playlist (ej. "quita las de este artista").
    *   **Crear playlist con IA** (Biblioteca): texto libre + panel de parámetros opcional (cantidad, máx. por artista, género/mood, familiaridad↔descubrimiento, nicho↔popular, "basado en una playlist mía") + iteración post-generación. La edición manual de la lista previa es local y gratuita; solo "afinar con IA" gasta una petición.
    *   **Crear cola con IA** (pantalla de Cola): toggles de cola nueva vs. basada en la actual, e intercalar vs. añadir como cola manual. **Absorbe el Smart Shuffle.**
    *   **Modificar playlist con IA** (menú de 3 puntos): modo *quitar* (schema restringido a IDs ya existentes en la playlist — no puede inventar qué borrar) y modo *agregar*.
    *   **Selector "basado en esta playlist" restringido a playlists propias**, nunca públicas/compartidas de terceros: evita que texto controlado por otro usuario entre al contexto de una IA que actúa con **tus** permisos.
*   **Búsqueda por fragmento de letra (IA):** Enviar el fragmento a Gemini protegido contra inyecciones de prompt para que identifique la canción y devuelva las coincidencias más probables en formato estructurado JSON. La app luego las busca en Deezer y las muestra como resultados normales. Entrada: un botón más junto a "Popular" y "Búsqueda profunda" en el buscador.
*   **Radio / cola infinita (SIN IA):** cuando la cola automática baja de 5 pistas, se generan 25 más usando `/artist/{id}/radio` y `/artist/{id}/related` de Deezer, con 5 artistas semilla elegidos por **muestreo aleatorio ponderado por frecuencia**, filtrado por `rank` y deduplicado. Activada por defecto. No consume presupuesto de Gemini.
*   **Crossfade** (transición suave entre canciones, exclusivamente en tracks locales/cacheados — ver Pitfall #17):
    *   **Windows (`media_kit`):** Investigar instancias duales de `media_kit` con fade-in/fade-out paralelo usando el control de volumen de cada instancia.
    *   **Android (`just_audio`):** `just_audio` soporta crossfade nativo usando dos `AudioPlayer` simultáneos; diseñar un `CrossfadeAudioHandler` que administre ambas instancias y el fade cruzado. Ambas plataformas deben quedar cubiertas en la Fase 7.
*   ~~Smart Shuffle (aleatorio con sugerencias).~~ → **Absorbido** como el toggle "intercalar con la cola automática" dentro de *Crear cola con IA* (ver `plan_fase_7.md`, decisión D-9). Se descartó como función separada porque un disparo automático y recurrente quemaría el presupuesto de RPD de Gemini; como acción explícita del usuario no hay ese riesgo.
*   Búsqueda por género.
*   Descubrimiento musical vía previews de Deezer (30s).
*   Compartir playlists (solo lectura).

---

## 3. Arquitectura y Stack Tecnológico

### Stack Confirmado
*   **Frontend:** Flutter (Dart). UI adaptativa Windows/Android.
*   **Motor de Audio (Dividido por plataforma):** 
    *   **Android:** `just_audio` + `audio_service` (ExoPlayer).
    *   **Windows:** `media_kit` (basado en `libmpv`, alto rendimiento en desktop).
*   **Controles del Sistema:** `audio_service` (Android) y `smtc_windows` (Windows).
*   **Base de Datos (Online-First):** Supabase (PostgreSQL) como fuente de la verdad, Drift (SQLite) como caché local para capacidades offline.
*   **Metadatos:** Deezer API.
*   **Letras Sincronizadas:** API de LRCLib (`lrclib.net`, open-source, sin llave requerida).
*   **IA:** Google AI Studio (Gemini).

### Arquitectura de Extracción (Core Resiliente)
Para que el reproductor no se rompa si YouTube cambia sus firmas, se usará un enfoque híbrido de tres niveles, con 0-Mantenimiento de APK:

1.  **Primario (Android + Windows, un solo código):** `youtubei.js` compilado a bundle único para navegador + **Paquete de Polyfills JS** (`fast-text-encoding`, `URL`, etc.) + QuickJS (`flutter_js`) corriendo en un **`Isolate.spawn` dedicado** (separado del Main Isolate de la UI) + puente `dartFetch` a Dart.
    *   **Inyección de Polyfills:** QuickJS carece de APIs Web nativas. Se concatenará un bundle de polyfills puros en JS para resolver `TextEncoder`, `TextDecoder` y `URL` antes de cargar `youtubei.js`. `setTimeout` se puenteará a `Future.delayed` en Dart vía canal síncrono.
    *   **Evitar BotGuard:** Se usarán clientes **estrictamente exentos de PoToken**, evitando las variantes `WEB`, `ANDROID_MUSIC` e `IOS` (las cuales pasaron a exigir PoToken obligatorio recientemente). BotGuard necesita un DOM real para computarse, algo que ni los polyfills pueden simular.
        *   **Jerarquía validada en Fase 1 (lección aprendida):** la lista teórica original (`tv` / `android_vr` / `tv_downgraded`) **quedó obsoleta** cuando YouTube endureció las políticas de firma/PoToken en `/player` para esos clientes en pistas protegidas (VEVO, música oficial). En la práctica, el cliente **`ANDROID`** (≠ `ANDROID_MUSIC`) resultó ser el único que entrega URLs directas pre-firmadas (`c=ANDROID`) que reproducen el 100% del catálogo, incluido VEVO. Por eso la jerarquía actual en producción es **`['ANDROID', 'ANDROID_VR', 'WEB']`** (definida en `extraction_isolate.dart`). `android_vr`/`tv` se conservan como fallback de respaldo. ⚠️ YouTube rota estas políticas con frecuencia: si `ANDROID` deja de funcionar, este es el primer lugar a revisar.
    *   **Optimización de Sesión:** Mantener el contexto de sesión de Innertube (visitorData, PoToken si aplica) vivo y reutilizado dentro del isolate en vez de reinicializar por cada canción. El PoToken se mina una vez y se reutiliza.
    *   **Riesgo del Puente:** El puente `dartFetch` en Dart debe manejar perfectamente redirecciones, cookies/sesión persistente y decodificación gzip/br para evitar fallos silenciosos entre Dart y JS.
    *   **Validación OTA (Seguridad):** El bundle JS se firmará en CI (Ed25519). La app validará la firma contra una llave pública local antes de ejecutarlo en QuickJS, previniendo ejecución de código remoto (RCE) si el bucket de Supabase es comprometido.
2.  **Secundario (Solo Windows):** Binario de `yt-dlp` invocado como proceso externo, autoactualizable consultando `api.github.com/repos/yt-dlp/yt-dlp/releases/latest`. Descargará el `SHA2-256SUMS` oficial para validar la integridad del `.exe` antes de reemplazarlo (prevención de ataque de cadena de suministro). Red de seguridad independiente y barata.
3.  **Terciario / Emergencia (Ambas plataformas):** Lista de instancias públicas de Piped (no self-host) con health-check y rotación automática. Estrictamente de uso exclusivo si los métodos Client-Side fallan masivamente (para darle tiempo al desarrollador de subir un parche OTA sin que la app muera por completo).

*(Descartado: NewPipeExtractor vía platform channel en Android porque obliga a recompilar el APK; la simbiosis Dart+JSON original porque no sobrevive a cambios estructurales de respuesta de YT; WebView headless por el riesgo de morir al apagar la pantalla y alto consumo).*

#### Análisis de Impacto de Cambios de YouTube y Matriz de Responsabilidades

> ⚠️ **Nota de estado (post-Fase 1):** La columna "¿Se soluciona con OTA?" describe el
> **objetivo final** de la arquitectura, que se cumple **una vez implementado el
> mecanismo OTA real** (firma Ed25519 + bucket de Supabase + validación en runtime —
> pendiente en la fase de Mantenimiento). Mientras tanto, el bundle JS viaja como asset
> bundled en el APK, por lo que *actualizar el bundle* equivale hoy a recompilar y
> republishear la app. Las filas marcadas OTA son válidas como **capacidad de diseño**.

| Evento de YouTube | ¿Se soluciona con actualización OTA de `youtubei.js`? | ¿Requiere cambios en el código de Flutter/Dart? |
| :--- | :---: | :---: |
| **Cambios en algoritmos de firma (`n-sig` / decipher)** | **SÍ (100%)** — Sin actualizar APK (objetivo OTA) | No requiere cambios en la app |
| **Nuevas restricciones PoToken (BotGuard)** | **SÍ (Mayoría)** — Actualizando el bundle JS | **SÍ (hoy)** — La jerarquía de clientes (`['ANDROID','ANDROID_VR','WEB']`) vive actualmente *hardcoded en Dart* (`extraction_isolate.dart`), así que ajustarla requiere recompilar el APK. **Mejora pendiente:** mover la jerarquía de clientes a un config dentro del bundle JS para que sea actualizable por OTA cuando el mecanismo de firma+bucket exista. |
| **Formato de Manifiestos (DASH / HLS)** | **SÍ (Extracción)** | Configurar el player nativo para recibir la URL del manifiesto |
| **Nuevas Web APIs usadas por la librería JS** | No | **SÍ** — Añadir el polyfill faltante en `JsBundleLoader` |
| **Políticas de Red / Headers en ExoPlayer (Android)** | No | **SÍ** — Ajustar la inyección de headers en `AudioSource.uri` o manifest nativo |

### Diseño de Datos (Supabase + Drift)
*   **Filtrado Rápido y Desnormalización:** Para evitar lentitud extrema causada por sentencias SQL `JOIN` masivas al abrir playlists grandes (500+ canciones), la tabla `playlist_tracks` en SQLite estará **desnormalizada**. Se guardarán campos redundantes como `artist_name`, `album_name` y `cover_url` en la misma fila de cada pista. Esto prioriza la velocidad de cálculo del CPU sobre el espacio de almacenamiento.
*   **Arquitectura Online-First:** Supabase es la fuente de la verdad y Drift actúa como caché. Permite la reproducción y lectura de datos offline, pero **la modificación (crear, editar, borrar playlists) requiere conexión obligatoria a internet** (los controles de edición se desactivan sin red). Esto evita conflictos de sincronización complejos y respeta la prioridad absoluta de la nube.
*   **Métricas Wrapped:** Las métricas anuales se pre-calculan de forma incremental en Supabase para no saturar el cliente leyendo historiales masivos a fin de año.

---

## 4. APIs, Límites, Escalabilidad y Seguridad

### 4.1 Límites duros verificados (Supabase free tier, 2026) y Gemini/Deezer

| Recurso | Límite | Fuente |
| :--- | :--- | :--- |
| Tamaño de base de datos (Postgres) | 500 MB | Supabase |
| Almacenamiento de archivos (Storage) | 1 GB | Supabase |
| Egress de base de datos | 5 GB/mes | Supabase |
| Egress de Storage | 5 GB/mes | Supabase |
| Usuarios activos mensuales (MAU, Auth) | 50,000 | Supabase |
| Invocaciones de Edge Functions | 500,000/mes | Supabase |
| Conexiones Realtime concurrentes | 200 | Supabase (no usado, ver 4.2) |
| Correo SMTP por defecto | **2 mensajes/hora** | Supabase (best-effort, no apto para producción) |
| Gemini 3.1 Flash-Lite (free tier, llave compartida) | 15 RPM / **1,000 RPD** / 250k TPM, sin tope de tokens/día publicado | Google AI |
| API Deezer | 50 req / 5 seg **por IP** | Deezer (la IP es la del usuario, no la nuestra — no es un límite global del proyecto) |

### 4.2 Cuánto pesa realmente un usuario — metodología

La tabla anterior son los límites de la plataforma; lo que falta (y es lo que realmente decide
cuántos usuarios soporta el proyecto) es **cuánto consume cada usuario de cada uno de esos
recursos**. Se modeló fila por fila usando los esquemas reales de `supabase/migrations/` y los
tamaños de columna típicos (texto de títulos/artistas, URLs de portada de Deezer, UUIDs, etc.).

**Dos tipos de crecimiento muy distintos conviven en el esquema**, y confundirlos es lo que hizo
que la primera estimación de este documento (~10,000 usuarios) fuera demasiado optimista:

- **Crecimiento acotado (llega a un techo, no depende de los años que pase el proyecto activo):**
  `playlist_tracks`, `playlists`, `saved_albums`. Un usuario construye su biblioteca y luego el
  ritmo de adición baja drásticamente. **Importante:** la app tiene **importación masiva desde
  CSV** (Spotify/Apple Music) como función central — un usuario que migra su biblioteca completa
  puede traer miles de pistas **el primer día**, no es un caso raro. `listening_history` también
  es acotado, pero por diseño: se poda a 90 días, así que su tamaño no crece con la antigüedad del
  usuario, solo con qué tan seguido escucha.
- **Crecimiento perpetuo (el único que escala con `usuarios × años`, sin techo):**
  `user_stats_monthly` (Fase 7) — suma una fila **garantizada** cada mes, para siempre, mientras
  el usuario siga activo. Es la única tabla de todo el esquema sin un techo natural — por eso tu
  instinto de revisarla para el horizonte de 5 años estaba justificado.

**Tamaño estimado por fila** (columnas reales de `20250001000000_initial_schema.sql` + overhead de
tupla de Postgres + índices, redondeado):

| Tabla | Tamaño/fila | Nota |
| :--- | :--- | :--- |
| `playlist_tracks` | **~400 bytes** | Desnormalizada a propósito (título, artista, álbum, portada) — es la fila más pesada del esquema |
| `listening_history` | **~150 bytes** | Acotada a 90 días por poda automática |
| `user_stats_monthly` | **~4 KB** | Top 50 artistas + top 50 canciones (solo `{id, minutos}`, sin nombres/portadas) + géneros, en JSONB |
| `playlists` / `saved_albums` | ~230 bytes | Pocas filas por usuario (decenas), footprint total despreciable |

**Perfil de consumo por usuario** (combinando ambos tipos de crecimiento):

| Perfil | `playlist_tracks` | `listening_history` (estable) | Base fija (una vez) | + Perpetuo (`user_stats_monthly`) |
| :--- | :--- | :--- | :--- | :--- |
| Ligero (~300 pistas, ~15 escuchas/día) | 114 KB | 200 KB | **~330 KB** | +48 KB/año |
| **Típico** (~1,500 pistas — incluye migración por CSV, ~40 escuchas/día) | 585 KB | 540 KB | **~1.1 MB** | +48 KB/año |
| Intensivo (~5,000 pistas, uso muy activo) | 1.9 MB | 540 KB | **~2.5 MB** | +48 KB/año |

### 4.3 Usuarios soportados por tamaño de base de datos (revisado)

Con el perfil **típico** (el más realista dado que la importación CSV es una función de primera
clase, no un caso extremo) y usando `base fija + 48 KB × años`:

| Horizonte | Free (500 MB) | Pro (8 GB, $25/mes) |
| :--- | :--- | :--- |
| Año 1 | ~490 usuarios | ~7,700 usuarios |
| **Año 5** (horizonte del proyecto) | **~410 usuarios** | **~6,500 usuarios** |
| Año 10 | ~340 usuarios | ~5,500 usuarios |

Con el perfil ligero el free tier llega a ~900-570 usuarios (año 1 → año 10); con el intensivo,
baja a ~330-180. El número real del proyecto estará en algún punto de ese rango según qué tanto se
use la importación masiva y qué tan activos sean los usuarios reales.

**Esto revisa a la baja la cifra anterior de "~10,000+ usuarios"**, que no tenía en cuenta el peso
real de `playlist_tracks` (desnormalizada, con URLs de portada largas) ni la tabla nueva de
estadísticas. La cifra de 10,000 sigue siendo razonable, pero **en el plan Pro**, no en el free
tier, y a partir de un horizonte de varios años.

> ⚠️ Estimación con supuestos razonables (tamaños de columna típicos, perfiles de uso), no una
> medición contra datos reales. Conviene revisar el tamaño real de las tablas en producción una vez
> haya usuarios activos, en vez de confiar ciegamente en estos números.

### 4.4 Qué límite se alcanza primero (todos los recursos, no solo la BD)

Ordenado de más urgente a menos, asumiendo actividad pareja entre usuarios:

| # | Recurso | Techo aproximado | ¿Es un techo real del proyecto? |
| :--- | :--- | :--- | :--- |
| 1 | **Gemini, llave compartida** | ~1,000 RPD repartidos entre todos — con ~3 peticiones/usuario/día activo de IA, del orden de unos cientos de usuarios activos de IA por día | No es un techo real: es exactamente el punto de transición a BYOK ya previsto en el diseño (cada usuario trae su propia llave). Mensaje explícito al usuario cuando se agota (ver `plan_fase_7.md`, 7.E.3b). |
| 2 | **Egress de base de datos** (5 GB/mes) | **No modelable con confianza** sin datos reales — depende de cuánto pide cada *pull-to-refresh* y de qué tan efectivo es el caché de 5 min (`SyncCacheManager`) | Desconocido. Recomendación: **medirlo en el dashboard de Supabase** una vez haya tráfico real, en vez de estimarlo a ciegas. Es el recurso con menos certeza de toda esta tabla. |
| 3 | **Tamaño de base de datos** (500 MB) | **~410 usuarios típicos a 5 años** (free tier) | Sí — es la preocupación original, y ahora la más urgente de las tres reales (ver 4.5, límite de cuentas). |
| 4 | Invocaciones de Edge Functions (500k/mes) | Con BYOK generalizado (Gemini deja de ser cuello de botella por usuario) y ~3 invocaciones/usuario/día, del orden de ~5,500 usuarios activos de IA por día | No, muy por encima de lo que la BD ya permite. |
| 5 | MAU de Auth (50,000) y Storage (1 GB) | Nunca se alcanzan antes que los recursos anteriores | No — el resto de la arquitectura limita mucho antes. |

**Nota sobre correo SMTP:** el límite de 2 mensajes/hora del servicio por defecto (4.1) **no aplica
a este proyecto** — el login principal es con Google OAuth y el secundario es correo+contraseña
**sin flujo de recuperación de contraseña** (aviso explícito al usuario de que no hay reset). La
app no envía correos, así que este límite queda fuera de la lista de riesgos. Se deja documentado
en 4.1 solo como referencia, por si en el futuro se agrega recuperación de contraseña como mejora
opcional.

**Conclusión práctica:** el tamaño de la base de datos (lo que originalmente preocupaba) es real y
es, de los riesgos que sí aplican a este proyecto, el más urgente — de ahí la decisión de limitar
cuentas (4.5). La llave compartida de Gemini ya tiene su solución de escalado prevista (BYOK). El
egress de base de datos sigue siendo el único recurso sin una cifra confiable — vale la pena
instrumentarlo cuando haya tráfico real.

### 4.5 Límite de cuentas y modo sin cuenta (decisión de producto)

**Contexto:** Syncora es un proyecto personal sin fines de lucro y sin presupuesto — se sostiene
enteramente en planes gratuitos. Dado que el techo real de la base de datos (~410 usuarios típicos
a 5 años, ~340 a 10 años, con margen de incertidumbre) ya es bajo por diseño, **la decisión es
limitar activamente el número de cuentas** en vez de descubrir el límite de forma reactiva cuando
la app deje de funcionar para alguien.

**El límite aplica solo a la cuenta con nube, nunca al uso de la app.** Streaming, búsqueda,
descargas offline y el modo local/sin cuenta completo (§4.6) son y seguirán siendo **ilimitados**
para cualquier usuario, incluso después de que se llenen los 250 registros. Lo único que se
restringe es la sincronización entre dispositivos y las funciones de IA, que dependen de una
identidad respaldada por Supabase.

> ✅ **Decidido e implementado en la Fase 7** (`plan_fase_7.md`, fases 7.H y 7.I — cerradas y
> aplicadas contra el proyecto real). Lo de abajo es la justificación; el checklist de
> implementación vive en el plan.

- [x] **Límite recomendado: 250 cuentas.** Es ~25-30% por debajo del techo teórico a 10 años
      (~340), dejando margen para: (a) la incertidumbre propia de una estimación no medida, (b) el
      egress de base de datos (recurso #2 de la tabla anterior, todavía sin medir), y (c) que la
      mezcla real de usuarios sea más pesada que el perfil "típico" modelado. Es fácil de subir
      más adelante si los datos reales muestran más margen del esperado, o si algún día se paga el
      plan Pro (eleva el techo a ~6,500) — es preferible partir conservador.
- [x] **Mecanismo:** Supabase Auth Hook **"Before User Created"** (función de Postgres o Edge
      Function invocada antes de que la cuenta se cree), que cuenta `auth.users` y rechaza el
      registro si ya se alcanzó el tope, devolviendo un error legible al cliente. Guardar el tope
      en una tabla de configuración de una sola fila (no hardcodeado), para poder subirlo con un
      `UPDATE` en vez de un redeploy.
      ⚠️ **Bug conocido de la plataforma:** al rechazar con un mensaje de error personalizado, el
      hook puede devolver un "Invalid payload sent to hook" genérico en vez del mensaje propio
      (issue abierto de Supabase). El cliente debe reconocer también ese error genérico como "cupo
      lleno" y mostrar el mensaje amigable igual, sin depender de que el texto personalizado llegue
      bien.
- [x] Mensaje al usuario cuando se alcanza el tope: explicar que las cuentas con nube están
      llenas, y **ofrecer el modo sin cuenta** (ver abajo) como alternativa siempre disponible, no
      un simple "inténtalo más tarde".

### 4.6 Modo sin cuenta / local (implementado, Fase 7.I)

Pregunta planteada: si se limita el número de cuentas, ¿puede alguien seguir usando la app sin
cuenta, 100% local, cuando el cupo esté lleno? **Sí es viable**, y encaja con la arquitectura
existente mejor de lo que parece: Drift ya funciona como caché local completo (Fase 4-6); lo único
que hoy obliga a tener conexión para editar es una decisión deliberada de diseño ("Online-First",
§3), no una necesidad técnica. Un modo sin cuenta simplemente **nunca activa el espejo a
Supabase** y deja a Drift como el único almacén — sin eso, no hay nada que mantener consistente
con la nube, así que la restricción de "editar requiere internet" deja de aplicar para ese usuario.

**Sigue funcionando sin cuenta** (no dependen de Supabase): reproducción, búsqueda y descubrimiento
en Deezer, descargas offline (Fase 6), auto-skip, crossfade, radio/cola infinita (Fase 7.B, es
puro Deezer), importación/exportación CSV, y estadísticas **locales** (Drift ya tiene
`listening_history` en el dispositivo).

**No funciona sin cuenta** (requieren identidad respaldada por Supabase): sincronización entre
dispositivos, compartir playlists públicamente, y las 4 funciones de IA (la Edge Function autentica
con el JWT del usuario; exponerla sin autenticar la dejaría abierta a abuso).

Esto además **suaviza el límite de cuentas**: en vez de "ya no se pueden crear cuentas", el mensaje
real es "las cuentas con nube están llenas, pero la app se puede seguir descargando y usando en
modo local, sin nube ni IA" — nadie queda completamente bloqueado. Es coherente con el objetivo ya
declarado del proyecto ("100% gratuito, privado") — de hecho, vale la pena ofrecerlo como opción
desde el día uno para quien no quiera cuenta en la nube, no solo como salvavidas cuando el cupo se
llene.

> ✅ **Decidido e incorporado a la Fase 7** (`plan_fase_7.md`, fase 7.I): se ofrece **desde el
> lanzamiento**, no solo al llenarse el cupo. Estadísticas en modo local: solo Semanal y Mensual
> (sin rollup mensual propio); Anual/Wrapped y "Desde el inicio" quedan como exclusivas de cuenta.
> El crecimiento sin poda de `listening_history` local (~2 MB/año) se acepta como insignificante.

### Seguridad y Mantenimiento
*   **Seguridad de Endpoints y Rate-Limiting:** La app no expone endpoints propios, consume APIs de terceros y Supabase. 
    *   **Inyecciones SQL:** Prevenidas por defecto al usar el SDK de Supabase (PostgREST) y Drift (SQLite), que utilizan consultas parametrizadas. Nunca concatenar strings en consultas.
    *   **Rate-Limiting (Supabase):** Las Edge Functions de Supabase (ej. para llamar a Gemini) y el flujo de Auth están protegidos automáticamente por el API Gateway de Supabase contra ataques DDoS y fuerza bruta.
    *   **Protección Deezer:** Limitador de peticiones (Rate Limit) interno en la app (Queue/Debouncer) para evitar baneos de IP por el límite de 50req/5s.
*   **Protección de Datos:** Políticas RLS (Row Level Security) mixtas. Para escritura (`INSERT`/`UPDATE`/`DELETE`), un usuario solo puede modificar registros con su UUID. Para lectura (`SELECT`), se permite acceder si el UUID coincide **O** si el recurso tiene la bandera `is_public = true` (necesario para la función de compartir playlists).
*   **Protección de IA (Límites, JWT y BYOK):**
    1.  **Límites de Uso:** Para evitar abusos financieros en la API de Gemini compartida, la Edge Function implementará un Rate Limit generoso por usuario (ej. máximo N llamadas por hora) validado en una tabla interna, mitigando ataques de bots.
    2.  **Seguridad RLS en IA (¡CRÍTICO!):** NUNCA se usará la `SERVICE_ROLE_KEY` dentro de las Edge Functions para ejecutar mutaciones sugeridas por la IA (ej. "borrar lista"). El cliente de Supabase interno se inicializará SIEMPRE con el JWT del usuario que invoca la función. Si la IA sufre una inyección de prompt (Prompt Injection) y trata de borrar todo, el RLS de la base de datos lo bloqueará matemáticamente.
    3.  **BYOK (Bring Your Own Key) — Flujo Explícito (¡CRÍTICO!):** Si el usuario provee su propia llave de Gemini, esta se guardará *exclusivamente* en local con `flutter_secure_storage`. El flujo de BYOK **NO bypasea la Edge Function**; en cambio, el cliente envía la llave en un header firmado (`X-User-AI-Key`) a la misma Edge Function, la cual la reenvía directamente a la API de Gemini sin guardarla. Esto garantiza que:
        *   El parseo a JSON estructurado y la protección anti-prompt-injection **siempre ocurren en la Edge Function**, sin duplicar lógica en el cliente.
        *   Las mutaciones sugeridas por la IA (ej. borrar canciones) **siempre pasan por el RLS-vía-JWT** del usuario, sin importar si usa llave propia o la compartida.
        *   La llave nunca toca la base de datos ni logs de Supabase; solo transita en memoria de la Edge Function y sale hacia Gemini.
        *   ⚠️ Consecuencia: en modo BYOK el límite de Rate Limit interno (punto 1) se omite o eleva, ya que el usuario paga su propio consumo.
*   **Mantenimiento (GitHub Actions):** Flujo CI/CD para compilar el bundle de `youtubei.js` + polyfills en cada parche, subirlo a Supabase Storage, y forzar la actualización OTA.
*   **✅ Cleartext Traffic en Android (resuelto en Fase 2):** `network_security_config.xml` tiene `<base-config cleartextTrafficPermitted="false"/>` global y `cleartextTrafficPermitted="true"` limitado únicamente a `127.0.0.1` y `localhost` (proxy interno de `just_audio`).

---

## 5. Fases de Implementación Actualizadas

*   **Fase 0:** Setup y Arquitectura. Proyecto Flutter base, `.env`, Gestor de Estado (ej. Riverpod/Bloc), Inyección de dependencias, y configuración de manifiestos nativos (Permisos Android 14+ FGS, setup Windows).
*   **Fase 1 (Spike Técnico):** El Motor Resiliente. Extracción end-to-end funcional vía el puente `dartFetch` inyectando los **polyfills JS** en QuickJS y resolviendo los `ReferenceError` de `youtubei.js`. Prueba aislada de reproducción de audio. **Se implementa aquí la política de Máximo 1 Reintento ante Error 403** (guard anti-bucle mínimo viable), ya que el motor de extracción que puede disparar ese error nace en esta fase.
*   **Fase 2:** Audio State y Controles del SO. Implementar `audio_service` (Android) y `smtc_windows` (Windows) como la única fuente de la verdad del estado de reproducción, acoplados a los motores (`just_audio` / `media_kit`). Implementación de Skip Silence usando `silencedetect` de libmpv (Windows) y el flag de ExoPlayer para podcasts (Android).
*   **Fase 3:** UI Core y Navegación. Esqueleto de la app, Rutas (GoRouter), Tema Premium (Paletas dinámicas), Mini-reproductor y Reproductor Fullscreen atados al estado de la Fase 2.
*   **Fase 4:** Datos y Metadatos. Integración Deezer API (Buscador, Detalles). Implementación de la BD local (Drift) desnormalizada para caché rápido de la UI. Implementación del flujo de importación/exportación de playlists (CSV/TXT).
*   **Fase 5:** Nube, Auth y Sincronización. Flujo de Autenticación Supabase. CRUD remoto de playlists, aplicación de políticas RLS mixtas (incluyendo el campo `is_public` desnormalizado en `playlist_tracks`) y sincronización por demanda Pull-to-Refresh + Caché TTL 5 min (sin WebSockets).
*   **Fase 6:** Motor Offline y Descargas Masivas. Implementación de la arquitectura JIT con `background_downloader` para evadir el Doze Mode, y Caché LRU de imágenes/audio.
*   **Fase 7:** Experiencia Premium y IA. Cola reordenable drag & drop, Auto-Skip inteligente completo (UI + cola dinámica), Crossfade en **ambas plataformas** (Windows: instancias duales `media_kit`; Android: `CrossfadeAudioHandler` con dos `AudioPlayer`), Integración Gemini con flujo BYOK unificado (Edge Function), Estadísticas Wrapped.
    *   📄 **Plan detallado y decisiones de diseño: `docs/plan_fase_7.md`** (leer antes de implementar). Amplía el alcance con: **sistema de cola dual** (automática regenerable + manual persistente, FIFO), **radio / cola infinita sin IA** (endpoints `/artist/{id}/radio` y `/related` de Deezer), y absorbe **Smart Shuffle** dentro de "Crear cola con IA" en vez de dejarlo como función aparte.
    *   ⚠️ **Prerequisito descubierto al planear:** `ListeningHistoryDao.recordEntry()` no tiene ningún llamador — el historial de escucha **nunca se ha registrado**, pese a existir la tabla, el DAO, la sincronización y consumidores en Inicio. Sin ese registro no hay datos para Estadísticas ni personalización real. Es el primer paso de la fase (7.0), junto con arreglar la duplicación de filas en `SyncService._syncListeningHistoryInternal()`.

---

## 6. Documentación Técnica de Referencia: Deezer API

*La API de Deezer es pública y no requiere llave para consultas básicas:*
*   **Búsqueda:** `https://api.deezer.com/search?q={query}`
*   **Álbum:** `https://api.deezer.com/album/{id}`
*   **Artista:** `https://api.deezer.com/artist/{id}`
*   **Top Canciones Artista:** `https://api.deezer.com/artist/{id}/top`

---

## 7. Migraciones, Base de Datos y Entorno (.env)

El **Agente (IA)** será el responsable de generar los archivos de migración SQL. El **Desarrollador** los aplica con `supabase db push` desde su terminal local.

### Separación de ambientes de llaves (regla crítica de seguridad)

| Llave | Dónde vive | Quién la usa |
| :--- | :--- | :--- |
| `SUPABASE_URL` | `.env` de la app (bundled en APK/EXE) | Flutter cliente — es pública por diseño |
| `SUPABASE_ANON_KEY` | `.env` de la app (bundled en APK/EXE) | Flutter cliente — pública, protegida por RLS |
| `SUPABASE_SERVICE_ROLE_KEY` | Variable local del SO del desarrollador o `.env.local` (jamás en Git, jamás en la app) | Solo Supabase CLI para migraciones |
| `GEMINI_API_KEY` | Secreto de Supabase Edge Functions (jamás sale del servidor) | Edge Functions en el servidor |

> **Por qué la ANON_KEY es segura en el APK:** Supabase la llama "anon/public" porque está diseñada para vivir en clientes. La seguridad no depende de ocultarla, sino del RLS: aunque alguien la extraiga con ingeniería inversa, no puede leer ni modificar datos de otros usuarios.

Al inicio del proyecto (Fase 0), el Agente solicitará al Desarrollador solo **2 piezas de información** para el `.env` de la app:
1. `SUPABASE_URL`: URL del proyecto de Supabase.
2. `SUPABASE_ANON_KEY`: Llave pública anon del proyecto.

La `SERVICE_ROLE_KEY` se pide por separado en Fase 5, solo cuando se necesita para las migraciones, y el desarrollador la configura en su entorno local, no en el código.

**Reglas de Git y Archivos `.env`:**
El archivo `.env` real (que contiene la `SERVICE_ROLE_KEY` o llaves privadas) DEBE estar estrictamente en el `.gitignore`. Lo único que se subirá a GitHub será el archivo `.env.example`, el cual solo contendrá llaves públicas y/o variables vacías.

**Archivo `.env.example` requerido en el repositorio:**
```env
# Variables públicas para la app Flutter (Es 100% seguro subir la ANON_KEY)
SUPABASE_URL=tu_url_aqui
SUPABASE_ANON_KEY=tu_anon_key_aqui
# Configuración local (solo desarrollo)
MOCK_API=false
```

---

## 8. Modelo de Datos (Esquema General)

El esquema relacional (reflejado tanto en Supabase como en Drift SQLite) constará de:
*   **`users`**: Gestionado por Supabase Auth (`auth.users`). Extendido con una tabla `profiles` (avatar, preferencias locales como "descargar solo con wifi").
*   **`playlists`**: `id`, `user_id` (FK), `title`, `description`, `cover_url`, `is_public` (bool), `folder_id` (FK opcional), `is_pinned` (bool), `order_index`, `created_at`, `updated_at`. *(Nota: La playlist de "Me Gusta" será una playlist normal con un flag especial o ID reservado).*
*   **`playlist_tracks`**: `id`, `playlist_id` (FK), `user_id` (FK - Desnormalizado para chequeo O(1) en RLS), **`is_public` (bool - Desnormalizado desde `playlists` para que la política de lectura pública sea también O(1) sin JOIN)**. `track_id` (ID de Deezer), `artist_id`, `album_id`, `genre`, `title`, `artist_name`, `album_name`, `cover_url`, `duration_ms`, `added_at`, `order_index`.
    *   ⚠️ **Consistencia de `is_public`:** Un trigger de PostgreSQL (`playlist_tracks_sync_is_public`) debe actualizar automáticamente `is_public` en todas las filas de `playlist_tracks` cuando cambia el campo `is_public` en la tabla `playlists`. Sin este trigger, el valor desnormalizado quedará desincronizado al hacer privada una playlist que era pública.
*   **`saved_albums`**: `id`, `user_id` (FK), `album_id` (Deezer), `title`, `artist_name`, `cover_url`, `added_at`.
*   **`folders`**: `id`, `user_id` (FK), `name`, `order_index`, `created_at`.
*   **`listening_history`**: `id`, `user_id`, `track_id`, `artist_id` (NUEVO), `album_id` (NUEVO), `genre` (NUEVO), `listened_at`, `duration_listened`. *(Nota de Escalabilidad: Un Cron Job mensual 'pg_cron' en Supabase agregará esta data cruda a una tabla `user_stats_monthly` y borrará filas mayores a 90 días para no saturar los 500MB).*
    *   ⚠️ **El orden del cron importa:** primero agregar el mes cerrado a `user_stats_monthly`, **después** podar a >90 días. Nunca al revés.
    *   **Criterio de registro (Fase 7):** una escucha se registra si supera el **50% de la duración o 30 segundos**, lo que sea menor. Sin ese umbral, una canción saltada a los 3 segundos contaminaría el top.
*   **`user_stats_monthly`** (Fase 7): `user_id`, `month`, `total_minutes`, `top_artists` (JSONB, top 50 con `{id, minutos}`), `top_tracks` (JSONB, top 50), `genres` (JSONB). **No guarda nombres ni portadas** — se resuelven con el caché de metadata de Deezer. Alimenta las vistas Anual y "Desde el inicio"; las vistas Semanal y Mensual se calculan sobre `listening_history` crudo (ventanas móviles de 7 y 30 días), no sobre esta tabla.

---

## 9. Estructura de Carpetas Sugerida (Feature-First)

Se recomienda una arquitectura modular (ej. Feature-First combinada con Clean Architecture) para mantener el código escalable:
```text
lib/
├── core/               # Configuraciones, tema, utils, puente dartFetch, excepciones.
├── data/               # Modelos, DTOs, Supabase client, Drift DB, APIs (Deezer).
├── features/           # Funcionalidades principales separadas
│   ├── auth/           # Login, registro, recuperación
│   ├── player/         # AudioHandler, UI del reproductor, Cola, Controles SO
│   ├── library/        # Playlists, álbumes guardados
│   ├── search/         # Buscador universal
│   └── download/       # Gestor JIT y background_downloader
└── main.dart
```

---

## 10. Guía de Diseño UI/UX y Antipatrones de IA

Para asegurar una apariencia Premium y evitar que la app luzca genérica, el Agente y el Desarrollador se apegarán a las siguientes directrices:

### Referencias y Assets
*   **Mockups:** El desarrollo visual se basará estrictamente en los mockups alojados en la carpeta `/mockups` generados por Google Stitch.
*   **Paquete de Íconos:** Se utiliza **`flutty_solar_icons`** (Solar Icons con variante *broken* de 1.5px por defecto y variante *bold* para elementos seleccionados/activos). Ofrece una estética moderna, limpia y consistente evitando la apariencia genérica de Material Icons.
*   **Avatares de Usuarios:** Para evitar pedir fotos personales y darle un toque lúdico, se usarán avatares generados proceduralmente (ej. estilo Kahoot o "Beanheads"). Se utilizará la API de **DiceBear** (o su paquete nativo Flutter) pasando el UUID único del usuario como "seed". Esto asegura que cada usuario tenga un avatar divertido, único y consistente asignado automáticamente sin gastar almacenamiento de base de datos en imágenes.

### Tipografía y Color
*   **Tipografía:** **Plus Jakarta Sans** (Moderna, limpia, muy legible; da un toque premium/tech perfecto para una app de música).
*   **Paleta de Colores:** 
    *   `Background` (Fondo principal - #181C27): El fondo más profundo de la app.
    *   `Surface` (Superficies/Tarjetas - #1E2633): Barra de navegación, tarjetas, mini-reproductor.
    *   `Surface Hover` (#252E3D): Al presionar o pasar el mouse.
    *   `Surface Active` (#2C3647): Elementos seleccionados activamente.
    *   `Primary` (Texto principal / Íconos activos - #FFFFFF): Títulos, botón Play.
    *   `Secondary` (Texto secundario / Íconos inactivos - #A0ABBA): Subtítulos, artistas, duraciones.
    *   `Muted` (Deshabilitado / Fondo sutil - #7F8C9D): Íconos de menú sin seleccionar, placeholders.

### Principios de Diseño
Para mantener la calidad "Premium" y evitar que parezca un MVP barato, sigue estas reglas al desarrollar:
1.  **Bloques Sólidos (No Glassmorphism):** Evitar transparencias en componentes de alto toque (mini-reproductor, nav-bar). Usar superficies sólidas y sombras para crear profundidad. (Glassmorphism solo es aceptable en el header con scroll).
2.  **Jerarquía Tipográfica Agresiva:** Títulos siempre en Bold o ExtraBold (700) con tracking ajustado negativo (-0.02em) para que se vean modernos. Texto secundario en Medium o Regular (400/500), nunca más ligero.
3.  **Sistema de Sombras "Glow":** Elementos primarios (botón Play, portadas destacadas) usan sombras blancas difuminadas (`box-shadow: 0 0 20px rgba(255, 255, 255, 0.15)`) en lugar de sombras negras comunes para emitir luz.
4.  **Botones Flotantes Reactivos:** Botones como el "Play" en tarjetas de canciones están ocultos por defecto y aparecen flotando al hacer hover/interactuar, haciendo que la app se sienta viva.
5.  **Cero Huecos Geométricos (Anidación de Bordes):** Componentes redondeados superpuestos deben anidarse perfectamente (radios coincidentes o padding negativo para desaparecer detrás) evitando huecos antiestéticos entre cajas.
6.  **Píldoras Consistentes:** Filtros siempre en formato pastilla inquebrantable (`px-4 py-1.5`, `whitespace-nowrap`). Scroll horizontal si no caben, jamás saltos a dos líneas.
7.  **Transiciones Cortas y SafeArea:** Respetar los Notches (SafeArea) y mantener las animaciones de hover/toque rápidas (máx 150-200ms) para que la app se sienta fluida y nada perezosa.

### Antipatrones de Diseño IA (Lo que se DEBE EVITAR)
El diseño debe verse intencional y humano. Se evitarán estas "señales delatoras" (tell-tale signs) del diseño generado por IA:
1.  **La Estética "AI-Slop":** Evitar gradientes excesivos (especialmente morado-a-azul), el abuso del *glassmorphism* (tarjetas de cristal esmerilado sin propósito) y avatares abstractos geométricos.
2.  **Layouts Predecibles y Genéricos:** Evitar el diseño "plantilla" estándar de componentes espaciados sin jerarquía. La app debe tener carácter (ej. un reproductor inmersivo, portadas que dicten el color del entorno, barras de navegación con personalidad).
3.  **La Falacia del "Happy Path":** El diseño generado por IA suele ignorar los bordes (edge cases). **Regla estricta UX:** Cada pantalla debe tener explícitamente diseñados sus **Empty States** (qué pasa si no hay playlists), **Error States** (qué pasa si no hay internet), y **Loading States** (Skeleton loaders en lugar de simples spinners circulares).
4.  **Botones sin Consecuencia (UX sin lógica):** La IA a menudo añade botones que se ven bien pero no hacen nada. Cada botón en la UI debe estar justificado y atado a la lógica de negocio o estado del reproductor.
5.  **Falta de Accesibilidad:** Evitar textos gris claro sobre fondos blancos/negros. Asegurar contraste y áreas de toque (touch targets) de mínimo 48x48dp para móviles.

---

## 11. Fase 8 (pendiente de planear)

> La Fase 7 cerró el plan de implementación tal como estaba definido hasta el punto anterior de
> este documento. Al revisar `Documento_Maestro.md` completo contra el código real (no solo contra
> checklists de fases) salieron a la luz algunas funciones que quedaron descritas en §2/§8 desde el
> diseño original pero **nunca se implementaron** — se habían perdido de vista precisamente porque
> nunca fueron un checkbox en ningún plan de fase.
>
> **Esta sección es solo una lista de alcance, todavía no un plan.** Falta decidir metodología de
> ejecución (¿una fase monolítica o varias sub-fases independientes?, ¿orden?, ¿qué amerita revisión
> independiente según el criterio de riesgo ya usado en Fase 7?) antes de empezar a implementar
> cualquiera de estos puntos. Se planeará después de terminar las pruebas manuales y correcciones de
> la Fase 7.

### Alcance de la Fase 8

- **Sistema OTA completo para el motor de extracción.** Hoy `youtubei.bundle.js` viaja únicamente
  como asset local empaquetado en la app (`lib/core/extraction/js_bundle_loader.dart` lo carga con
  `rootBundle.loadString`, sin ninguna descarga remota) — actualizarlo requiere recompilar y
  republicar la app, exactamente lo que el diseño original (§3, "Arquitectura de Extracción")
  buscaba evitar. Falta construir: el bucket de Supabase Storage, la firma Ed25519 del bundle en CI
  y su validación en runtime antes de ejecutarlo en QuickJS, el pipeline de GitHub Actions que
  compila/firma/sube el bundle en cada parche, y mover la jerarquía de clientes de fallback (hoy
  hardcodeada en `extraction_isolate.dart`) a config remota actualizable por OTA (deuda anotada
  desde `docs/fases/fase_1.md`).
- **Carpetas para playlists.** §2.1.3 ("Ordenar por carpetas") y §8 (tabla `folders`) las describen,
  pero la tabla `folders` nunca se creó en ninguna migración y no hay ningún código de carpetas en
  `lib`. Hoy solo existe "fijar" (`isPinned`), no organización jerárquica.
- **Búsqueda por género**, integrada en las tarjetas de la pantalla del buscador. §2.4 la menciona;
  no existe ningún filtro ni endpoint de búsqueda por género hoy.
- **Descubrimiento musical vía previews de Deezer (30s).** El campo `previewUrl` ya se parsea y se
  guarda en el modelo de cada track (viene directo del JSON de Deezer), pero no se reproduce en
  ningún lado de la UI — falta el mecanismo de reproducción de preview en sí.
- **Lanzamientos nuevos de artistas escuchados**, personalizados. Lo que existe hoy
  (`DeezerApi.getNewReleases()`) es el chart global de Deezer (`/chart/0/albums`), no una lista
  filtrada a los artistas que el usuario realmente escucha.
