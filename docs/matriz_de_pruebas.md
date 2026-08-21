# Matriz de Pruebas y QA (Syncora Player)

Este documento sirve como un Checklist para garantizar que cada fase cumpla con sus objetivos sin introducir regresiones. 

**Estrategia de Velocidad:** 
- La IA escribirá **Pruebas Automatizadas (Unit/Widget Tests)** para la lógica matemática y de estado.
- El Humano hará **Pruebas Rápidas** durante cada fase para validar la UI y el audio básico.
- Las **Pruebas Complejas y de Estrés** (Edge Cases) se reservan para el final del ciclo de desarrollo, evitando cuellos de botella iniciales.

---

## Fase 0: Setup y Arquitectura
- [ ] **Automatizado (IA):** Compilación limpia del proyecto base en Windows y Android (sin errores de dependencias).
- [ ] **Humano (Rápido):** Iniciar la app; verificar que la configuración de variables de entorno (`.env`) cargue sin crashear.

## Fase 1: El Motor Resiliente (Spike Técnico)
- [ ] **Automatizado (IA):** Unit tests del puente `dartFetch` (verificar manejo de redirecciones HTTP y decodificación GZIP/Brotli). Unit tests de carga de polyfills en QuickJS. **Unit test del guard anti-bucle 403:** verificar que el motor intenta exactamente 1 reintento y luego emite `PlayerError.rateLimited` sin continuar.
- [ ] **Humano (Rápido):** Ingresar un ID de YouTube duro en el código y verificar que el audio se extraiga y suene.
- [ ] **Final/Complejo:** Testear la extracción de una pista regionalmente bloqueada para validar que el sistema falle con gracia y no crashee la app entera.

## Fase 2: Audio State y Controles del SO
- [ ] **Automatizado (IA):** Tests del Gestor de Estado (Mock de transiciones lógicas: Playing -> Paused -> Buffering). **Test de Skip Silence:** verificar que en Windows el filtro `silencedetect` produce un seek al inicio del audio real (no a t=0).
- [ ] **Humano (Rápido):** Reproducir una pista, pausar y reanudar sin problemas lógicos. Activar Skip Silence y confirmar que el audio de una pista con intro silenciosa empieza inmediatamente.
- [ ] **Final/Complejo:** 
    - Reproducir música, apagar la pantalla del celular y validar que el widget de la pantalla de bloqueo funcione.
    - Presionar botones multimedia del teclado físico en Windows y validar que pausen/pasen la canción.
    - Probar interrupciones (recibir una llamada en Android mientras suena la música).

## Fase 3: UI Core y Navegación
- [ ] **Automatizado (IA):** Widget tests de la barra de navegación y enrutamiento (GoRouter).
- [ ] **Humano (Rápido):** Navegar rápidamente entre Inicio, Biblioteca y Buscar. Verificar que las transiciones corran a 60fps (sin lag o parpadeos).
- [ ] **Final/Complejo:** Probar SafeArea en móviles (verificar que el contenido no quede oculto detrás de la muesca de la cámara o la barra inferior de gestos del sistema).

## Fase 4: Datos y Metadatos
- [ ] **Automatizado (IA):** Tests unitarios del *Debouncer* y limitador de cola de peticiones de la API de Deezer. Tests de CRUD local en SQLite (Drift). **Test del flujo de importación:** parsear un CSV de 10 pistas y verificar que genera 10 búsquedas serializadas en Deezer (una a la vez, con debouncing).
- [ ] **Humano (Rápido):** Buscar un artista y validar que se muestre. Guardar una playlist local, reiniciar la app y ver si sigue ahí. **Importar un archivo CSV de prueba (5 canciones) y verificar que la playlist se crea correctamente. Exportar la playlist creada y abrir el CSV resultante.**

## Fase 5: Nube, Auth y Sincronización
- [ ] **Automatizado (IA):** Tests lógicos de la cola de sincronización (Drift <-> Supabase Mock). **Test del trigger `playlist_tracks_sync_is_public`:** cambiar `is_public` en `playlists` y verificar que todas las filas de `playlist_tracks` reflejan el nuevo valor automáticamente.
- [ ] **Humano (Rápido):** Flujo completo de Login. Crear una playlist y validar que sube a Supabase.
- [ ] **Final/Complejo:**
    - **Online-First Edit:** Apagar WiFi, intentar editar el nombre de una playlist y verificar que la interfaz bloquee/deshabilite la acción correctamente. Prender WiFi y verificar que se habilite.
    - **RLS Test:** Autenticarse como Usuario A, intentar (vía script o API) borrar una playlist del Usuario B. Debe fallar por RLS.
    - **RLS Playlist Pública:** Con Usuario A, hacer una playlist pública, obtener su link. Con Usuario B (sin autenticar o cuenta diferente), verificar que puede leer las pistas de esa playlist sin error.

## Fase 6: Motor Offline y Descargas Masivas
- [ ] **Automatizado (IA):** Lógica del caché LRU para imágenes (verificar que deseche portadas viejas al llenarse).
- [ ] **Humano (Rápido):** Descargar 1 canción, apagar WiFi, intentar reproducirla.
- [ ] **Final/Complejo:**
    - **Doze Mode:** Iniciar descarga de playlist, apagar pantalla del móvil, dejarlo 15 mins. Validar que la descarga no fue asesinada por el SO.
    - **Estrés:** Descargar una playlist de +300 canciones de golpe.

## Fase 7: Experiencia Premium y IA

> Plan detallado: `docs/plan_fase_7.md`.

- [ ] **Automatizado (IA):** Algoritmo de reordenamiento de cola (verificar que el índice se actualiza matemáticamente). Tests de las Edge Functions (con mocks). **Test del flujo BYOK unificado:** verificar que la Edge Function recibe el header `X-User-AI-Key` y lo usa para llamar a Gemini (mock) sin guardarlo ni loguearlo.
    - **Cola dual:** agregar 2 pistas manuales seguidas respeta FIFO; cambiar shuffle↔normal **no** toca la cola manual; cambiar de playlist **no** toca la cola manual; "anterior" tras consumir una manual vuelve a esa manual; las pistas consumidas se eliminan de la cola; restaurar sesión reconstruye ambas colas.
    - **Radio/cola infinita:** muestreo ponderado por frecuencia, deduplicación, filtro de `rank`, y completado con `/related` cuando hay menos de 5 artistas distintos (fixtures grabadas, sin llamadas en vivo).
    - **Registro de historial (7.0):** umbral de escucha (justo por debajo/encima; pista corta <60s donde manda la regla de 30s) y **no-duplicación al sincronizar** (regresión de `_syncListeningHistoryInternal`).
    - **Estadísticas:** ventanas móviles de 7/30 días, suma correcta de 12 meses, y usuario con menos de 12 meses de historial (el Anual debe funcionar igual).
- [ ] **Humano (Rápido):** Arrastrar y soltar una canción en la cola. Ingresar un texto en el buscador IA. **Activar Crossfade en una pista descargada en Windows y verificar la transición suave. Hacer lo mismo en Android.**
    - Agregar canciones a la cola manual, cambiar de playlist y verificar que **siguen ahí**.
    - Generar una playlist con IA y **cancelar** en la vista previa: verificar que **no se escribió nada** en la BD.
- [ ] **Final/Complejo:** 
    - Auto-skip al límite: Tener 3 canciones seguidas no disponibles en YT y verificar que la app salte velozmente a la 4ta sin congelarse. **Con el guard de cascada (7.C.3), el comportamiento esperado ahora es que se detenga y avise tras la 3ra, no que siga saltando.**
    - Forzar manualmente el Cron Job mensual en la base de datos y verificar que agrupe los datos de escucha sin romper historiales actuales. **Verificar el orden: agrega el mes ANTES de podar a 90 días.**
    - **BYOK vs. Llave compartida:** Activar modo BYOK, ejecutar una petición de IA y verificar que la respuesta llega correctamente y la llave nunca aparece en logs de Supabase.
    - **Radio infinita con playlist de 1 solo artista:** dejar sonar hasta que se agote la cola y verificar que no repite en bucle al mismo artista (debe tirar de `/related`).
    - **Modificar playlist con IA (quitar):** dar una instrucción ambigua y verificar que la vista previa permite revisar/desmarcar antes de borrar, y que cancelar no borra nada.
    - **Límite de cuentas (7.H):** bajar temporalmente `max_accounts` al número actual de usuarios e intentar registrarse **por correo y por Google** — ambas vías deben rechazarse con el mensaje amigable, no con un error genérico. Restaurar el valor después.
    - **Modo local (7.I):** entrar sin cuenta, crear playlists **con el WiFi apagado** (debe permitirlo), cerrar y reabrir la app (el modo local persiste), y verificar que no aparecen botones de IA/compartir/sincronizar.
    - **Migración local → cuenta (7.I.10):** con biblioteca local ya creada, registrarse y subirla; verificar que sube completa y que reintentar tras un corte no duplica playlists.
