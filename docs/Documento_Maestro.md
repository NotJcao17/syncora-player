# Documento Maestro de Planeación y Arquitectura: Syncora Player

**Proyecto:** Syncora Player  
**Repositorio:** `https://github.com/NotJcao17/syncora-player.git`  
**Objetivo:** Reproductor de música nativo (Windows/Android) 100% gratuito, privado, enfocado en resiliencia y diseño premium.

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
*   **1.6 Detalle de Artista:** Info de Deezer, canciones más escuchadas, discografía.
*   **1.7 Playlist/Álbum:** Portada (default: cuadrícula generada automáticamente con las primeras 4 portadas **distintas** de la lista, o color/degradado a elección del usuario), nombre, autor, duración, número de canciones. Botones rápidos: aleatorio, descargar, play, guardar, menú 3 puntos (editar, eliminar, compartir pública/privada, agregar a otra). Lista de pistas con mini menú (3 puntos: agregar a playlist, agregar a cola, descargar pista, ver álbum, ver artista, **corregir coincidencia de YT / fix match**, compartir).
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
*   Funciones IA (Gemini): Generar playlist por prompt de texto, generar cola de reproducción por prompt de texto, modificar playlist (ej. "quita las de este artista").
*   **Búsqueda por fragmento de letra (IA):** Enviar el fragmento a Gemini protegido contra inyecciones de prompt para que identifique la canción y devuelva las 3 coincidencias más probables en formato estructurado JSON. La app luego las busca en Deezer.
*   **Crossfade** (transición suave entre canciones, exclusivamente en tracks locales/cacheados — ver Pitfall #17):
    *   **Windows (`media_kit`):** Investigar instancias duales de `media_kit` con fade-in/fade-out paralelo usando el control de volumen de cada instancia.
    *   **Android (`just_audio`):** `just_audio` soporta crossfade nativo usando dos `AudioPlayer` simultáneos; diseñar un `CrossfadeAudioHandler` que administre ambas instancias y el fade cruzado. Ambas plataformas deben quedar cubiertas en la Fase 7.
*   Smart Shuffle (aleatorio con sugerencias).
*   Bloqueo de artistas/canciones.
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

### Tabla de Límites, Escalabilidad y Soluciones

| Recurso (Supabase Free) | Límite Actual | Usuarios Aprox. Soportados | Solución al Escalar (Siguiente Paso) |
| :--- | :--- | :--- | :--- |
| **Correos SMTP** | 2-3 correos por hora | ~10 a 20 registros diarios | Desactivar confirmación por correo temporalmente, o conectar Resend/SendGrid en Supabase (Costo: $0 a $15/mes). |
| **Conexiones WebSockets** | 200 concurrentes | ~3,000 a 5,000 MAU | Apagar actualizaciones en tiempo real (Supabase Realtime) y cambiar a *Pull-to-refresh* o *REST GET* normal. |
| **Tamaño de BD (Postgres)**| 500 MB | ~10,000+ usuarios | Pagar el plan Pro de Supabase ($25/mes) que eleva el límite a 8GB. |
| **Almacenamiento (Storage)**| 1 GB | Infinito | Como se usan CDNs de Deezer y avatares procedurales, no se almacenan archivos pesados de usuario. Límite irrelevante. |
| **API Deezer** | 50 req / 5 seg por IP | Infinito | La petición se hace desde el celular del usuario, por ende **usa la IP del usuario, no nuestro servidor**. Cada usuario tiene su propio límite, evadiendo baneos globales. |

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
*   **Fase 5:** Nube, Auth y Sincronización. Flujo de Autenticación Supabase. CRUD remoto de playlists, aplicación de políticas RLS mixtas (incluyendo el campo `is_public` desnormalizado en `playlist_tracks`) y sincronización bidireccional (Nube <-> Local).
*   **Fase 6:** Motor Offline y Descargas Masivas. Implementación de la arquitectura JIT con `background_downloader` para evadir el Doze Mode, y Caché LRU de imágenes/audio.
*   **Fase 7:** Experiencia Premium y IA. Cola reordenable drag & drop, Auto-Skip inteligente completo (UI + cola dinámica), Crossfade en **ambas plataformas** (Windows: instancias duales `media_kit`; Android: `CrossfadeAudioHandler` con dos `AudioPlayer`), Integración Gemini con flujo BYOK unificado (Edge Function), Estadísticas Wrapped.

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
*   **`yt_matches`**: `track_id` (PK), `youtube_video_id`, `corrected_at` (Persiste las correcciones manuales de coincidencias de YouTube permanentemente).
*   **`blocked_items`**: `id`, `user_id` (FK), `item_type` (enum: artist/track), `item_id`.
*   **`listening_history`**: `id`, `user_id`, `track_id`, `artist_id` (NUEVO), `album_id` (NUEVO), `genre` (NUEVO), `listened_at`, `duration_listened`. *(Nota de Escalabilidad: Un Cron Job mensual 'pg_cron' en Supabase agregará esta data cruda a una tabla `user_stats_monthly` y borrará filas mayores a 90 días para no saturar los 500MB).*

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
*   **Paquete de Íconos:** Se utilizará **`lucide_icons`** (o su equivalente en Flutter `lucide_icons_flutter`). Es un paquete excelente, moderno, consistente y con trazos limpios que evita el aspecto anticuado de los Material Icons por defecto.
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
