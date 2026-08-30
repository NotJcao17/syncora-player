# Investigación y Pitfalls (Trampas) a Evitar

Este documento recopila las trampas técnicas más comunes y destructivas al desarrollar un clon de Spotify/Deezer en Flutter. Los agentes IA deben consultar este archivo obligatoriamente antes de sugerir o implementar arquitectura.

## 1. El Riesgo de Proxies y APIs de Terceros (Piped)
*   **El Error (Pitfall):** Depender *exclusivamente* o como método *primario* de una API pública (como Piped) alojada en un servidor de terceros.
*   **Por qué falla:** YouTube bloquea masiva y rápidamente las IPs de los datacenters lanzando errores HTTP 403 o exigiendo Captchas.
*   **La Regla:** La extracción primaria debe ser **100% Client-Side** usando la IP residencial del usuario (QuickJS o yt-dlp). Las APIs de terceros (Piped) **SOLO** están permitidas como un mecanismo terciario/de emergencia (Fallback), para mantener la app viva en caso de que las firmas locales fallen repentinamente, dándole tiempo al desarrollador de subir un parche OTA.

## 2. Inyección Dinámica vs Código Compilado (0-Mantenimiento vs Polyfills)
*   **El Error (Pitfall):** Intentar ejecutar `youtubei.js` en `flutter_js` asumiendo que solo basta con puentear el `fetch`.
*   **Por qué falla:** QuickJS es un motor JS puro y no trae APIs Web (DOM) ni Node APIs por defecto. `youtubei.js` lanzará `ReferenceError` al no encontrar `TextEncoder`, `URL`, o `setTimeout`.
*   **La Regla:** El "0-Mantenimiento" exige inyectar un **Paquete de Polyfills JS** (ej. `fast-text-encoding`) en el mismo archivo antes de cargar `youtubei.js`. El puente de Dart debe encargarse de la red (`dartFetch`) y de `setTimeout`. El Spike Técnico (Fase 1) consistirá en atrapar y resolver estos `ReferenceError` incrementalmente.

## 3. Metadata: Deezer API vs Spotify
*   **El Error (Pitfall):** Usar la API de Spotify (Development Mode) en apps gratuitas desde 2026.
*   **Por qué falla:** Spotify ha deprecado el acceso a sus APIs públicas para apps de terceros no comerciales, limitando severamente los endpoints o exigiendo revisiones empresariales.
*   **La Regla:** Utilizar exclusivamente la **API de Deezer** para buscar metadata (títulos, portadas, álbumes). Es pública, no requiere llave compleja para consultas básicas, y devuelve previsualizaciones de audio de 30s.

## 4. El Cuello de Botella del Buscador (Rate Limit)
*   **El Error (Pitfall):** Implementar un buscador "en vivo" (que dispara peticiones HTTP en cada pulsación de tecla) contra la API de Deezer sin precauciones.
*   **Por qué falla:** Deezer te baneará temporalmente la IP (Error 429) por exceder su cuota de peticiones por segundo.
*   **La Regla:** Obligatorio implementar **Debouncing** de al menos 500ms en el campo de texto de búsqueda y cachear los últimos 10 términos buscados en la sesión.

## 5. Drift (SQLite) en Main Thread vs Background Isolate
*   **El Error (Pitfall):** Procesar inserciones de 500 canciones a una playlist en Drift ejecutando la consulta en el hilo principal (UI).
*   **Por qué falla:** SQLite bloqueará el hilo de Dart por varios milisegundos, provocando pérdida de frames (jank) o congelamiento temporal del scroll.
*   **La Regla:** El procesamiento pesado o importaciones masivas deben delegarse a un hilo en background. Usa **`NativeDatabase.createInBackground(file)`** al inicializar Drift. Esto transparentemente mueve todas las operaciones de I/O de la base de datos a un isolate secundario, sin requerir la compleja arquitectura manual de los `DriftIsolate` antiguos.

## 6. Pruebas Automáticas y Crashes de Inicialización (Web)
*   **El Error (Pitfall):** Creer que la IA no puede probar la UI y el código de Flutter. O intentarlo y sufrir crashes inmediatos por paquetes nativos (C++) como `media_kit`, `sqlite3` o motores JS (`flutter_js`).
*   **La Regla (Para Agentes):** El agente debe implementar un *bypass* de inicialización usando `if (!kIsWeb)` para cargar bases de datos, reproductores y **Servicios de Extracción de YouTube** "Mock" (falsos/en memoria) en entornos web. Con esto asegurado, el agente puede probar localmente la UI y llamadas a API ejecutando: `flutter run -d chrome --web-browser-flag "--disable-web-security"`. El servicio de extracción falso debe devolver una URL a un archivo `.mp3` de prueba genérico.

## 7. Gapless Mejorado y Transiciones
*   **El Error (Pitfall):** Usar la función nativa `player.setSkipSilenceEnabled(true)` de ExoPlayer (`just_audio`) asumiendo que sirve para hacer gapless entre canciones.
*   **Por qué falla:** `setSkipSilenceEnabled` usa un procesador interno para saltar silencios *dentro* del audio (ej. en podcasts o llamadas). No está diseñado para recortar padding al inicio/final de tracks, y causará artefactos audibles al intentar transicionar. El Gapless verdadero en ExoPlayer depende del padding ID3/M4A y del API interno de pre-carga.
*   **La Regla:** En **Android (`just_audio`)**, el gapless se delega nativamente a ExoPlayer utilizando la **Playlist API (`player.setAudioSources([source1, source2])`)**, confiando en que ExoPlayer lea los metadatos de padding incrustados. `setSkipSilenceEnabled` solo se habilita opcionalmente para contenido spoken-word/podcasts (silencios largos *dentro* de una pista), nunca para gapless entre canciones musicales. En **Windows (`media_kit`)**, se usa el filtro nativo `--af=lavfi=[silencedetect=noise=-50dB:duration=0.3]` capturando el log de ffmpeg para detectar los bordes de silencio y hacer un seek manual. ⚠️ `scaletempo` es un filtro de cambio de velocidad (pitch-preserving), NO de detección/recorte de silencio — no lo uses con este propósito.

## 8. WebView Headless vs Isolate Dedicado (El Puente dartFetch)
*   **El Error (Pitfall):** Intentar usar un WebView Oculto (Headless) para extraer firmas, o hacer la extracción en el *Main Thread* de la UI.
*   **Por qué falla:** Un WebView requiere un contexto visual (Activity). Al apagar la pantalla, el OS mata el contexto y la reproducción se congela. Además, son detectables por BotGuard. Y ejecutar la extracción en el Main Isolate (donde corren la UI y el `AudioHandler` de `audio_service` v0.18+) congelará los frames de la UI durante la desencriptación pesada de YouTube.
*   **La Regla:** Toda la extracción primaria (`flutter_js` con polyfills) DEBE correr en un **`Isolate.spawn` dedicado**, separado del Main Isolate. El `AudioHandler` (que vive en el Main Isolate) se comunica con este isolate de extracción vía `SendPort`/`ReceivePort`. QuickJS sobrevive intacto sin UI dentro de ese isolate. **Cuidado con el puente:** El puente `dartFetch` debe manejar perfectamente redirecciones, cookies y decodificación gzip/br, y el sistema requiere inicializar `BackgroundIsolateBinaryMessenger` en el isolate hijo.

## 9. Fugas de Memoria (OOM) por Portadas de Alta Resolución
*   **El Error (Pitfall):** Renderizar múltiples carátulas de álbumes en listas o cuadrículas sin limitar su tamaño en memoria.
*   **Por qué falla:** Aunque se usen imágenes pequeñas visualmente (ej. 100x100px), si la imagen original descargada de Deezer es de 1000x1000px, Flutter la decodificará completa en la RAM. En pantallas como "Inicio" o "Biblioteca", esto saturará rápidamente la memoria (Heap), provocando un cierre forzoso de la app (Crash por *Out of Memory*).
*   **La Regla:** Los agentes DEBEN usar siempre el paquete `cached_network_image`. Adicionalmente, es **obligatorio** especificar las propiedades `memCacheWidth` o `memCacheHeight` (ej. a 300). **Cuidado Crítico (Windows):** Este paquete usa `sqflite` internamente, el cual no es nativo en Windows. DEBES inicializar `sqflite_common_ffi` en el `main()` antes de correr la app, o de lo contrario la app hará crash.

## 10. Corrupción de Base de Datos: Rutas Absolutas en Descargas
*   **El Error (Pitfall):** Guardar en SQLite (Drift) la ruta absoluta del archivo mp3 descargado (ej. `/data/user/0/com.app/app_flutter/downloads/song.mp3`).
*   **Por qué falla:** Los sistemas operativos móviles pueden (y van a) cambiar la ruta del directorio interno de la app durante actualizaciones. Si la BD tiene rutas absolutas, los archivos aparecerán como "No Encontrados".
*   **La Regla:** En la Base de Datos DEBEN guardarse única y exclusivamente **Rutas Relativas** (ej. `/canciones/song.mp3`). Al intentar reproducir, la app calcula la ruta dinámica con `path_provider`.

## 11. El Bloqueo por Cambio de Red (IPs Firmadas) y Bucles de 403
*   **El Error (Pitfall):** Asumir que un Error HTTP 403 siempre es por un cambio de IP de red (WiFi a 4G) y forzar reintentos infinitos en silencio.
*   **Por qué falla:** YouTube lanza 403 por bloqueos de red, pero también por baneos temporales de BotGuard, rate-limits o geobloqueos. Reintentar ciegamente creará un bucle infinito de milisegundos que freirá el CPU y asegurará el bloqueo de la IP.
*   **La Regla:** Implementa una política estricta de **Máximo 1 Reintento** ante un error 403. Si el segundo intento falla, el reproductor DEBE PAUSARSE INMEDIATAMENTE y notificar al usuario visualmente. NUNCA reintentar en bucle ciego. ⚠️ **Esta protección se construye en la Fase 1 (Spike Técnico)** junto con el motor de extracción, no se difiere para fases posteriores.

## 12. Falsa Asunción de Isolates (audio_service y SQLite)
*   **El Error (Pitfall):** Asumir que `audio_service` corre en un *Background Isolate* separado de la UI y forzar a la base de datos a usar arquitecturas complejas de sincronización de hilos.
*   **Por qué falla:** Desde la v0.18.0, `audio_service` ejecuta el `AudioHandler` en el **mismo Main Isolate** que la UI. Si la UI muere, el motor mantiene vivo el Main Isolate. Intentar mandar el audio a un isolate secundario manual destruirá la integración de lockscreen.
*   **La Regla:** Comparte la misma instancia estándar de SQLite (Drift) y Supabase entre la UI y tu `AudioHandler` libremente. Gracias a la regla del Pitfall 5 (`createInBackground`), el I/O pesado de la BD no congelará el Main Isolate. *Excepción crítica:* El motor JS de extracción (`flutter_js`) SÍ debe mandarse a un `Isolate.spawn` real para la desencriptación de YT.

## 13. Rechazo 403 por Discrepancia de Headers HTTP
*   **El Error (Pitfall):** Hacer *Spoofing* de Headers (ej. User-Agent) en Dart para engañar a YouTube y extraer la URL, pero no pasarle esos mismos Headers a `media_kit` o al descargador.
*   **Por qué falla:** YouTube detectará que la firma se generó para un cliente (ej. TV) pero el audio lo está pidiendo otro (libmpv), provocando un bloqueo silencioso (403).
*   **La Regla:** Toda librería que haga la petición de streaming o descarga DEBE recibir explícitamente los mismos Headers con los que se generó la firma.

## 14. El Loop Infinito de la Muerte (Auto-Skip por Red)
*   **El Error (Pitfall):** Configurar el reproductor para hacer "Auto-skip" ciego a la siguiente canción cuando ocurre un error de conectividad (ej. `SocketException`) o Error HTTP 403.
*   **Por qué falla:** Si el usuario pierde el internet, el reproductor saltará rápidamente canción tras canción intentando conectar, vaciando una playlist de 100 canciones en 2 segundos y asegurando un baneo de IP por Spam.
*   **La Regla:** El Auto-Skip se ejecutará fluidamente ante errores lógicos (metadata no encontrada). Si el error es de red o conectividad (403), se permite **Máximo 1 Reintento** para amortiguar saltos de red móvil (alineado con la Sec. 2.3). Si vuelve a fallar, el reproductor DEBE pausarse inmediatamente.

## 15. Fuga de Seguridad Crítica (Gemini API Key)
*   **El Error (Pitfall):** Guardar llaves de API (como la de Google AI Studio) directamente en el cliente de Flutter mediante un archivo `.env` o en código duro.
*   **Por qué falla:** Las variables `.env` inyectadas en un APK no están encriptadas. Bots extraerán tu API Key mediante ingeniería inversa.
*   **La Regla:** Las llamadas a Gemini **jamás** deben hacerse desde Dart en el cliente. Deben enrutarse a través de una **Edge Function de Supabase**.

## 16. Inanición del Streaming por Cola de Descargas (Bloqueo del Event Loop JS)
*   **El Error (Pitfall):** Encolar descargas masivas en la misma cola FIFO que atiende las peticiones de streaming en vivo de la UI.
*   **Por qué falla:** Si el usuario manda a descargar 200 canciones y luego da Play a una en vivo, el streaming quedará atrapado detrás de las descargas en el Isolate JS, congelando la app indefinidamente.
*   **La Regla:** El gestor de extracción DEBE implementar una **Cola de Prioridad Preemptiva**. Las solicitudes de *Streaming* tienen prioridad absoluta (P0) y deben pausar de inmediato el bucle de las descargas (P1), extrayendo la URL solicitada para que la música suene, y luego reanudando el trabajo offline.

## 17. Crossfade Real vs Streaming en Vivo
*   **El Error (Pitfall):** Intentar hacer crossfade real reproduciendo directamente desde YouTube.
*   **Por qué falla:** Hacer crossfade real requiere dos conexiones activas bajando datos masivos simultáneamente, duplicando la carga en CPU y disparando baneos de IP (Error 429).
*   **La Regla:** El crossfade real DEBE limitarse exclusivamente a tracks que ya estén descargados/cacheados localmente.

## 18. PoToken / BotGuard y la Trampa de los Clientes Móviles
*   **El Error (Pitfall):** Configurar el motor de extracción (`youtubei.js`) con clientes WEB o clientes móviles clásicos (`ANDROID_MUSIC`, `IOS`, `androidSdkless`).
*   **Por qué falla:** En 2025/2026, YouTube expandió la exigencia de BotGuard (PoToken) a casi todos los clientes móviles. El BotGuard requiere un DOM real (window/document), algo que un motor JS embebido como QuickJS no tiene. Si usas Android o iOS, fallarás con Error 403 de inmediato.
*   **La Regla:** El extractor DEBE configurarse para "fingir" ser un cliente 100% exento de PoToken. ⚠️ **Actualización post-Fase 1:** la lista teórica original (`android_vr`, `tv`, `tv_downgraded`) **ya no funciona** para pistas protegidas (VEVO / música oficial): YouTube endureció las políticas de firma/PoToken en `/player` para esos clientes, devolviendo `Streaming data not available`. En la práctica, el cliente que mejor resuelve hoy todo el catálogo es **`ANDROID`** (ojo: **≠ `ANDROID_MUSIC`**, que sí exige PoToken). La jerarquía validada en producción es **`['ANDROID', 'ANDROID_VR', 'WEB']`** (definida en `extraction_isolate.dart`). YouTube rota estas políticas con frecuencia: si una película de repente falla, este es el primer sitio a revisar. Si todos los clientes móviles terminan exigiendo DOM, el ecosistema entero entrará en crisis.

## 19. Crash Seguro en Android 14+ (MissingForegroundServiceType)
*   **El Error (Pitfall):** Configurar `audio_service` e iniciar la reproducción de audio sin actualizar los manifiestos nativos para Android 14.
*   **Por qué falla:** A partir de Android 14 (API 34), es obligatorio declarar el tipo exacto de Foreground Service. Si se omite, el OS lanza una SecurityException fatal al dar 'Play'.
*   **La Regla:** Es imperativo agregar el permiso `<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />` y el atributo correspondiente en `<service>`.

## 20. Paradoja de URLs Efímeras en Descargas Masivas (Doze Mode)
*   **El Error (Pitfall):** Delegar descargas masivas de YouTube a un manejador de "caja negra" como `flutter_downloader` mandando cientos de URLs encoladas de golpe, o intentar correrlas dentro del `AudioHandler` de `audio_service`.
*   **Por qué falla (URLs efímeras):** Las URLs directas de YouTube caducan (típicamente en 6 horas) y están atadas a la IP. Si la red cambia o pasa tiempo, las URLs morirán y la descarga nativa fallará irrevocablemente, ya que no puede pedir a Dart que regenere las firmas.
*   **Por qué falla (AudioHandler):** Meter descargas en el `AudioHandler` de `audio_service` tiene dos problemas: (1) cuando la música se pausa/para, Android libera el Foreground Service de `mediaPlayback` y las descargas mueren; (2) en Android 14+, usar un FGS de tipo `mediaPlayback` para transferencia de datos viola las políticas del sistema y puede lanzar `SecurityException`.
*   **Por qué falla (`flutter_background_service`):** Este paquete tiene conflictos conocidos con `audio_service` — ambos crean motores de background Flutter independientes, causando errores de `"Duplicate plugin key"` y crashes. Además, no soporta Windows.
*   **La Regla:** Para descargas masivas, el flujo debe ser estrictamente **Just-In-Time (JIT)**. Dart extrae la URL de la Canción N → la descarga → extrae la URL de la Canción N+1. La implementación se divide por plataforma:
    *   **Android:** Usar el paquete `background_downloader` (que usa `WorkManager` internamente). Se le pasa cada URL individualmente conforme Dart las extrae. `WorkManager` maneja Doze Mode y la persistencia nativamente sin conflictos con `audio_service`. **Requisito Android 14+:** Declarar `<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />` y `android:foregroundServiceType="dataSync"` en el `<service>` correspondiente del `AndroidManifest.xml`.
    *   **Windows:** No existe Doze Mode. Usar `dio` directamente en un `Isolate.spawn` o el mismo `background_downloader` (que soporta Windows nativamente).

## 21. BYOK Bypasando la Edge Function (Dos Caminos de Seguridad)
*   **El Error (Pitfall):** Implementar el modo BYOK (Bring Your Own Key) enviando la llave del usuario **directamente** desde Dart al endpoint de Gemini, saltando la Edge Function de Supabase.
*   **Por qué falla:** Existen dos consecuencias críticas: (1) La lógica de protección anti-prompt-injection y el parseo a JSON estructurado que vive en la Edge Function tendrian que **duplicarse en el cliente**, generando dos caminos de seguridad divergentes que se desincronizarán con el tiempo. (2) Las mutaciones de IA (ej. "borra esta playlist") ejecutadas en modo BYOK no pasarían por el RLS-vía-JWT que es la defensa principal, anulando la garantía matemática de que un prompt injection no puede borrar datos de otro usuario.
*   **La Regla:** El cliente **SIEMPRE** enruta las llamadas de IA a la misma Edge Function, independientemente de si usa llave propia o la compartida. En modo BYOK, la llave viaja en un header firmado (`X-User-AI-Key`) que la Edge Function usa para llamar a Gemini y descarta sin guardar. De esta forma, hay **un solo camino de seguridad** para ambos modos.

## 22. Importación Masiva Sin Flujo Definido (Herramientas Externas)
*   **El Error (Pitfall):** Documentar "soporte de importación masiva" sin especificar el formato de entrada ni cómo se maneja la búsqueda de cada pista.
*   **Por qué falla:** Herramientas como TuneMyMusic o Soundiiz exportan listas en formatos variados (CSV, JSON, texto plano). Sin un parser claro y una cola con rate limiting, importar 500 canciones puede disparar 500 peticiones simultáneas a Deezer y resultar en ban de IP temporal (Error 429).
*   **La Regla:** El flujo de importación debe: (1) Aceptar archivos CSV o texto plano (campos mínimos: título + artista). (2) Parsear localmente sin servidor. (3) Buscar en Deezer de forma serializada con debouncing entre peticiones (respetar el pitfall #4). (4) Presentar al usuario las coincidencias ambíguas para confirmación antes de agregar. La exportación genera un CSV con: `título, artista, álbum, duración_ms`.

## 23. Crossfade Solo en Una Plataforma (Inconsistencia de Paridad)
*   **El Error (Pitfall):** Diseñar el crossfade solo para Windows (`media_kit`) y dejarlo pendiente o no diseñado para Android.
*   **Por qué falla:** Si no se planea desde el inicio, se llega a la Fase 7 con la función funcionando en una sola plataforma, lo cual obliga a una refactorización de la abstracción del `AudioHandler` en un momento tardío del proyecto.
*   **La Regla:** Ambas plataformas deben tener un diseño explícito desde el Documento Maestro. **Windows:** Instancias duales de `media_kit` con control de volumen cruzado. **Android:** `just_audio` soporta dos instancias `AudioPlayer` simultáneas; implementar un `CrossfadeAudioHandler` que gestione el fade-in/fade-out entre ambas. En ambos casos, el crossfade está **restringido a tracks cacheados/descargados** (ver Pitfall #17).

## 24. Fallback Silencioso de Audio Falso (MP3 de Prueba en Producción)
*   **El Error (Pitfall):** Devolver una URL de audio de prueba de terceros (ej. MP3 de 6 minutos de SoundHelix) como un `ExtractionSuccess` cuando la resolución o matching de un videoId de YouTube falla.
*   **Por qué falla:** Provoca que ante fallos intermitentes de red o resolución de IDs no-YouTube (ej. Deezer IDs), el usuario escuche un audio genérico no relacionado de ~6 minutos en lugar de la canción real.
*   **La Regla:** Si la resolución o matching de YouTube falla, el Isolate de Extracción DEBE devolver un `ExtractionFailure` explícito (`ExtractionError.notFound`). La app gestionará el error pausando o pasando limpiamente al siguiente track según la política de reintentos, pero NUNCA reproduciendo contenido no relacionado disfrazado de éxito. Adicionalmente, el resolver de IDs debe usar Innertube Search (`yt.search`) client-side en QuickJS con scoring de metadatos en Dart (`YtSearchMatcher`), eliminando la fragilidad del scraping HTML.

## 25. Bug de Transparencia y Glitches de DirectComposition/DWM en Segundo Monitor (Windows + Nvidia)
*   **El Error (Pitfall):** Al maximizar o mover la ventana de Flutter Desktop a un segundo monitor conectado a una GPU Nvidia (o setup con monitores a distinta tasa de refresco/escala DPI), la ventana se vuelve completamente transparente o presenta artefactos de composición gráfica/stuttering severo.
*   **Por qué falla:** Es un problema de sincronización entre el Desktop Window Manager (DWM) de Windows, DirectComposition y la capa de abstracción gráfica de Flutter en Windows (ANGLE / Direct3D 11 backend). En configuraciones multi-monitor con Nvidia, la sincronización de swapchain y presentación de buffers (`IDXGISwapChain1::Present1`) entre adaptadores gráficos o monitores con distintas frecuencias de actualización puede perder el contexto de DirectComposition cuando la ventana entra en estado maximizado (`WM_SIZE` con `SIZE_MAXIMIZED`), haciendo que DWM interprete el área de cliente como transparente o no inicializada.
*   **Soluciones y Workarounds:**
    1. **Configuración de Controladores Nvidia:** En el Panel de Control de Nvidia → *Controlar la configuración 3D* → *Configuración de programa* (para el ejecutable de Syncora Player) → Establecer *Modo de baja latencia* en "Ultra" / desactivar *Sincronización vertical rápida* o configurar *Modo de administración de energía* en "Máximo rendimiento preferido".
    2. **Flag de Inicialización Flutter Desktop:** Si el problema persiste en desarrollo nativo de Flutter Windows, deshabilitar la composición transparente si no se requiere explícitamente (`window_manager` con `setHasShadow(true)` y fondo opaco forzado en `flutter_windows.dll` o inicializar la ventana con estilo opaco `WS_EX_NOREDIRECTIONBITMAP` en el `runner/win32_window.cpp`).
    3. **Ajuste de Escala / Tasa de Refresco:** Alinear las tasas de refresco (ej. 60Hz/144Hz) o factores de escala DPI en la configuración de pantalla de Windows entre ambos monitores para evitar el desfasaje del DWM presentation clock.



---

> Los pitfalls 26 a 30 se descubrieron **en producción**, durante la ronda de QA
> posterior a la Fase 7, cada uno tras varios intentos fallidos de arreglo. El
> relato completo (síntomas, intentos equivocados y por qué costaron tanto) está
> en `docs/fases/correcciones_qa_post_fase_7.md`.

## 26. `just_audio.play()` NO completa al empezar, sino al TERMINAR la pista

*   **El Error:** `AudioPlayer.play()` de `just_audio` devuelve un `Future` que
    completa cuando la reproducción **termina** (fin de pista, pausa o stop), no
    cuando arranca. `JustAudioEngine.play()` hacía `return _player.play();`, así
    que `await _engine.play()` en el controlador se bloqueaba durante toda la
    canción.
*   **El Síntoma:** el botón "siguiente" quedaba muerto tras el primer uso.
    `skipToNext()` mantiene el guard `_isTransitioning` mientras espera, así que
    el segundo tap salía por el guard **sin generar un solo log**. "Revivía" al
    tocar la barra de progreso o poner otra canción, porque eso paraba el motor
    y completaba el future pendiente.
*   **Solo en Android:** `media_kit` (Windows) retorna en cuanto emite el
    comando, así que el bug era invisible ahí.
*   **La Regla:** nunca esperar `play()` de `just_audio` en un camino que
    sostenga un guard o bloquee una transición de UI. El motor debe cumplir el
    contrato "`play()` retorna cuando el comando se emitió", no cuando el audio
    acabó.

## 27. Los fakes de test deben imitar la asincronía real del motor

*   **El Error:** el `FakeAudioEngine` de la suite emitía sus estados de forma
    **síncrona** dentro de `setUrl`/`play`, y completaba `play()` de inmediato.
    Los motores reales no hacen ninguna de las dos cosas.
*   **El Síntoma:** 400+ tests en verde mientras el reproductor estaba roto en el
    teléfono. El pitfall #26 era invisible para toda la suite.
*   **La Regla:** un fake de motor de audio debe reproducir la **semántica** del
    real (emisión asíncrona, `play()` que no completa hasta el final), no solo su
    interfaz. Cuando un bug solo aparece en dispositivo, sospechar primero del
    fake antes que del código de producción.

## 28. Escribir solo en Drift = el sync lo borra

*   **El Error:** varias acciones (corazón del mini reproductor, del reproductor
    a pantalla completa, de la barra de tareas de Windows y de la pantalla de
    bloqueo de Android) llamaban directo al DAO de Drift sin subir el cambio a
    Supabase.
*   **El Síntoma:** la acción parecía funcionar y se revertía al recargar. Es
    consecuencia directa de la arquitectura Online-First (§3 del Documento
    Maestro): Supabase es la fuente de la verdad, así que el sync poda toda fila
    local que no exista en el servidor. **No es un bug de sincronización: es el
    comportamiento correcto ante un dato que nunca se subió.**
*   **La Regla:** toda escritura de biblioteca va por un servicio compartido que
    persiste en ambos lados (ej. `lib/features/library/services/like_track_service.dart`).
    Si una pantalla nueva llama al DAO directamente, es un bug.

## 29. `null` en un `update` parcial: "no lo toques" vs. "ponlo a NULL"

*   **El Error:** `SupabasePlaylistRepository.updatePlaylist` construía el mapa de
    cambios con `if (coverUrl != null) updates['cover_url'] = coverUrl;`. No había
    forma de expresar "guarda NULL".
*   **El Síntoma:** volver a portada automática (o vaciar la descripción) se
    guardaba en local pero nunca viajaba a la nube, y el siguiente sync restauraba
    el valor viejo.
*   **La Regla:** en updates parciales, un parámetro nulo es ambiguo. Usar flags
    explícitos (`clearCoverUrl`, `clearDescription`) o un tipo envoltorio.

## 30. Borrar por `track_id` elimina TODAS las copias

*   **El Error:** "eliminar duplicados" borraba en local las filas sobrantes por su
    id de fila (correcto) pero en Supabase llamaba a
    `removeTrackFromPlaylist(remoteId, trackId)`, que borra **todas** las filas con
    ese `track_id`, incluida la que se quería conservar.
*   **El Síntoma:** quedaba 1 copia en local y 0 en la nube; al recargar, el sync
    podaba la local y la canción desaparecía entera.
*   **La Regla:** cuando la operación local es "por fila" y la remota es "por
    valor", no son equivalentes. Tras un borrado remoto por valor hay que reponer
    explícitamente lo que debía sobrevivir.
