# Correcciones de QA posteriores a la Fase 7

Registro de la ronda de pruebas manuales que siguió al cierre de la Fase 7.
Además de listar qué se corrigió, este documento explica **por qué varias
correcciones rompieron cosas que funcionaban** — esa parte importa más que la
lista, porque el coste real de esta ronda no estuvo en escribir los arreglos sino
en las regresiones que introdujeron.

> Los cinco fallos técnicos de fondo están resumidos como **Pitfalls #26 a #30**
> en `docs/investigacion_y_pitfalls.md`. Aquí queda el relato: los síntomas, los
> intentos equivocados y qué método habría acortado el camino.

---

## 1. El caso que costó diez intentos: el botón "siguiente" muerto en Android

Vale la pena contarlo entero porque **cada intento fallido fue un error de método
distinto**, y son errores repetibles.

### Síntoma

En Android, el primer "siguiente" funcionaba; a partir de ahí el botón quedaba
muerto. No cambiaba el audio, ni la UI, y **no aparecía ni un solo log**. Tocar la
barra de progreso o poner otra canción lo "revivía". En Windows nunca ocurrió.

### Causa real

`JustAudioEngine.play()` hacía `return _player.play();`. En `just_audio` ese
`Future` completa cuando la reproducción **termina**, no cuando arranca
(Pitfall #26). Como `skipToNext()` sostiene el guard `_isTransitioning` mientras
espera a `playCurrent()`, el guard quedaba tomado durante toda la canción y el
segundo tap salía en la primera línea del método.

Todo encajaba con eso: el primer skip funciona porque la reproducción inicial
viene de `setQueue()`, que no toma el guard; y "revive" al parar el motor porque
eso completa el `Future` pendiente.

**El arreglo final fue una línea:** `unawaited(_player.play());`.

### Por qué costó diez intentos

1. **Se buscó en la capa equivocada.** El síntoma era "el botón no responde", así
   que se asumió un problema de UI o de guard mal liberado y la investigación se
   quedó en el controlador. El error estaba una capa más abajo, en una línea del
   motor que parecía trivial y correcta.

2. **La suite de tests daba falsa seguridad.** El `FakeAudioEngine` completaba
   `play()` de inmediato, así que 400+ tests en verde no significaban nada para
   este fallo (Pitfall #27). Cuando por fin se escribió un motor de prueba con la
   semántica real, **el test se colgó al primer intento** y confirmó el
   diagnóstico en segundos.

3. **Se parchearon síntomas en vez de buscar la causa.** Los primeros ocho
   intentos añadieron timeouts, reintentos y manejo de errores sobre hipótesis
   plausibles. Ninguno tocó la causa, y varios introdujeron regresiones nuevas
   (ver §2).

4. **El dato decisivo llegó tarde.** Lo que resolvió el caso fue la observación
   del usuario de que **el segundo skip no producía ningún log**. Eso descarta de
   golpe cualquier hipótesis de "algo se cuelga a mitad" y señala una salida
   temprana por un guard. Debió pedirse ese dato en el primer intento.

---

## 2. Regresiones introducidas al intentar arreglar cosas

Todas se revirtieron. Se documentan porque el patrón es lo que hay que evitar.

### 2.1 Un escritor en segundo plano sobre el motor de audio

Para arreglar "canciones que se quedan cargando" se añadió un vigilante que, 8
segundos después de cada arranque, volvía a llamar `setUrl`/`play` si no le
constaba que hubiera empezado. Es **un escritor concurrente sobre el motor sin
ninguna sincronización**: si el usuario pulsaba "siguiente" en esa ventana, dos
`setUrl` se pisaban sobre el mismo motor (que en Android además gestiona dos
instancias para el crossfade).

> **Regla:** nada debe escribir en el motor de audio fuera del camino de
> reproducción del controlador. Un `isStale()` comprobado *antes* de la llamada no
> protege de una carrera: entre la comprobación y el `await` cabe cualquier acción
> del usuario.

### 2.2 Sonda de conectividad para todas las plataformas

`connectivity_service.dart` solo consultaba `connectivity_plus` ("¿hay interfaz de
red?"). Para detectar "wifi sin internet" en Windows se añadió una sonda de
alcanzabilidad real **para todas las plataformas** (primero socket TCP a
`1.1.1.1:53`, luego HTTPS).

En el teléfono del usuario esa sonda fallaba pese a haber internet perfecto. Y el
daño no fue solo el aviso de offline: `syncora_player_controller.dart` tiene

```dart
if (_isConnectedGetter?.call() == false) return;   // _maybeFetchRadio
```

así que la app creyéndose offline **dejaba de rellenar la cola de radio**, la cola
se vaciaba y el "siguiente" pasaba a no hacer nada. Un bug de conectividad se
manifestó como un bug del reproductor.

> **Regla:** la detección de conectividad es específica de plataforma. En Android,
> la interfaz de red **es** una señal fiable — no añadir sondas ahí. La sonda solo
> tiene sentido en escritorio, con arranque optimista y varios fallos consecutivos
> antes de declarar offline.
>
> **Regla:** antes de tocar `isConnectedProvider`, buscar todos sus consumidores.
> Alguno gatea funcionalidad del reproductor.

### 2.3 Banderas de estado global en el reproductor

Para tapar un parpadeo visual de la barra de progreso se añadió una bandera que
suprimía posiciones `0`, limpiada al final del arranque. Cuando quedaba pegada,
**toda pista siguiente arrancaba en el segundo viejo**, la barra se congelaba y la
sesión dejaba de guardarse: un error, cuatro síntomas aparentemente distintos.

> **Regla:** en el reproductor, evitar banderas que alguien deba acordarse de
> limpiar. Si hace falta una ventana de supresión, que venza sola (por tiempo) o
> esté atada al id de la pista dueña, para que no pueda filtrarse a la siguiente.

### 2.4 `onError`/`onExit` en el isolate de extracción

Se añadieron para no perder peticiones si el isolate moría. Pero en Dart `onError`
recibe **cualquier error asíncrono no capturado**, no solo los fatales, y ese
isolate hace mucho trabajo asíncrono. Cualquier error suelto marcaba el puerto
como caído y forzaba **relanzar el isolate entero** (recargar el bundle JS y
reinicializar QuickJS: segundos) en el siguiente skip.

> **Regla:** `Isolate.spawn(onError:)` no es "avísame si se muere". Antes de usarlo,
> confirmar que los errores que llegan ahí son realmente fatales.

### 2.5 Un comentario XML rompió el build de Android

Un comentario con `--` dentro de `styles.xml` es XML inválido y dejó la app sin
compilar en Android, bloqueando todas las pruebas.

> **Regla:** tras tocar cualquier XML de `android/`, compilar antes de dar por
> cerrado el cambio. `flutter analyze` y `flutter test` **no** ven esos archivos.

---

## 3. Correcciones de persistencia (todas del mismo patrón)

El patrón dominante de la ronda: **acciones que escribían en Drift pero no en
Supabase**. La arquitectura es Online-First, así que el sync poda toda fila local
que no exista en el servidor — la acción parecía funcionar y se revertía al
recargar (Pitfall #28).

| Acción | Qué pasaba | Corrección |
| :--- | :--- | :--- |
| Me gusta desde mini reproductor / pantalla completa | Solo Drift; además mandaba `artistId`/`albumId` en 0 y sin género | Todo pasa por `toggleTrackLike` |
| Me gusta desde barra de tareas (Windows) y pantalla de bloqueo (Android) | Solo Drift | `toggleTrackLikeWith`, variante con dependencias explícitas para código sin `WidgetRef` |
| Portada de playlist → automática | El `null` nunca se enviaba (Pitfall #29) | Flags `clearCoverUrl`/`clearDescription` |
| Eliminar duplicados | Borraba todas las copias en la nube (Pitfall #30) | Se repone la copia que sobrevive |
| Minutos escuchados | Dejaba de contar al cruzar el umbral de 30s | Sigue acumulando y corrige la duración al terminar |
| Historial de escucha | Solo subía al arrancar o al refrescar Estadísticas | Se sube al registrar cada escucha (con throttle) |

> **Regla:** una pantalla nueva **nunca** llama al DAO directamente para escribir
> biblioteca. Va por el servicio compartido que persiste en ambos lados.

---

## 4. Otras correcciones

- **Arranque con DNS no listo:** en frío, Android tarda un par de segundos en
  resolver DNS. Las primeras llamadas a Deezer y el sync inicial morían en
  silencio (Inicio vacío, cambios de otro dispositivo sin aparecer). Se añadió
  `lib/core/utils/startup_retry.dart`, que reintenta **solo** ante fallos de red
  transitorios — un 404 o un error de parseo se propaga igual.
- **Barra de tareas de Windows:** los controles al pasar el mouse no son SMTC sino
  `ITaskbarList3::ThumbBarAddButtons`, que `smtc_windows` no expone. Se
  implementó nativo en `windows/runner/thumbnail_toolbar.cpp`.
- **Cierre de ventana colgado 10s:** `media_kit` agenda `mpv_terminate_destroy`
  tras un `Future.delayed(5s)` propio, duplicado por las dos instancias del
  crossfade. La ventana ya no espera a la limpieza.
- **Franja inferior en Android:** con edge-to-edge y navegación por gestos,
  Android **ignora** `systemNavigationBarColor`. El tono lo pinta la propia barra
  de navegación extendiendo su padding.
- **Portadas:** los modelos guardan `cover_medium` (250×250). El reproductor pide
  1000×1000 reescribiendo la URL del CDN de Deezer.

---

## 5. Método recomendado para la próxima ronda

Lo que habría ahorrado la mayor parte del tiempo perdido:

1. **Ante una regresión, revertir primero.** Si algo funcionaba antes, el primer
   movimiento es `git diff` contra el último estado bueno y quitar lo propio, no
   añadir código nuevo encima. Los commits están separados justamente para eso.

2. **Un fallo que solo aparece en dispositivo suele ser un fake mentiroso.**
   Antes de teorizar, escribir un test que imite la semántica real de la
   dependencia. En este proyecto eso destapó el bug en un intento después de que
   ocho fracasaran.

3. **Pedir el dato que discrimina.** "¿Aparece algún log al pulsar?" separa "se
   cuelga a mitad" de "sale por un guard" — y son investigaciones opuestas. Vale
   más que cualquier hipótesis.

4. **Verificar que el test falla sin el arreglo.** Un test que pasa antes y
   después no prueba nada.

5. **No cambiar comportamiento diseñado de paso.** Si un arreglo rompe un test que
   fija una decisión anterior, eso no es un test viejo: es una decisión que hay que
   respetar o discutir aparte.

6. **La puerta de calidad de este proyecto son tres cosas, no dos:**
   `flutter analyze` + `flutter test` + **compilar Android** (`gradlew
   assembleDebug`). Las dos primeras no ven los XML de `android/` ni el runner
   nativo de Windows.

---

## 6. Segunda ronda de QA

Ocho puntos reportados. El método de §5 se siguió al pie: antes de tocar nada
se buscó el dato que discrimina, y **dos de los ocho no eran lo que parecían**
(§6.7 y §6.8). Cada arreglo lleva un test que se verificó fallando sin él.

### 6.1 La conectividad "se dormía" tras unos minutos (Windows)

La sonda periódica estaba gateada por un flag `interfaceUp` alimentado **solo**
por `connectivity_plus`. Si ese stream reportaba la interfaz caída y después no
avisaba de que había vuelto (algo habitual en Windows), el flag quedaba en
`false` para siempre y la sonda se convertía en un no-op permanente: la app no
volvía a detectar internet nunca.

Además la sonda en sí medía lo que no debía: `InternetAddress.lookup` de un
nombre. El cliente DNS de Windows cachea, así que puede "resolver bien" con el
cable desconectado; y `Future.timeout` **no cancela** el `getaddrinfo`
subyacente, así que cada sonda colgada dejaba un hilo del pool de I/O de la VM
bloqueado — acumulados, agotan el pool.

Correcciones: la sonda periódica ya no se apaga nunca (la interfaz caída es
solo una señal rápida para declarar offline; quien decide volver a online es
siempre la sonda), y se cambió a `Socket.connect` contra **IPs literales**
(`1.1.1.1:53`, `8.8.8.8:53`), que sí aborta de verdad y no pasa por el
resolver. La máquina de estados se extrajo a `DesktopConnectivityMonitor` para
poder testearla. **El camino de Android no se tocó** (§2.2).

### 6.2 Acciones que escriben en la nube sin gatear

Inventario completo de escrituras a Supabase. Faltaban:

| Sitio | Qué pasaba offline |
| :--- | :--- |
| Corazón de la pantalla de bloqueo (Android) y del hover de la barra de tareas (Windows) | Escribía solo en Drift; el sync lo revertía |
| Guardar/quitar álbum (`album_detail_screen`) | Ídem |
| Menú de 3 puntos de la playlist (editar, pública/privada, copiar a otra, deduplicar, eliminar) | Ídem, y ver abajo |
| "Eliminar de la playlist" del menú de pista | Ídem |
| "Guardar cola como playlist" | Ídem |
| Cambiar avatar | Fallaba con un error genérico |

Los dos primeros son controles del SO: no hay botón que pintar en muted, así
que la acción **no se ejecuta** y se avisa por un `PlayerNotice` nuevo
(`blockedOffline`) que `app_shell.dart` ya sabe mostrar como toast.

**Lo más grave estaba en `_executeRemoteMutation`** (`playlist_detail_screen`):
sin conexión, tanto el `select` de comprobación como la mutación fallan, y
**los dos caminos de error interpretan ese fallo como "la playlist ya no existe
en la nube" y borran la copia local**. Es decir: estar offline podía borrarte
una playlist entera por un diagnóstico equivocado. Ahora corta antes de llegar
ahí.

### 6.3 Hueco muerto en el buscador de canciones de la playlist

El intento anterior quitó dos `SizedBox(height: 16)` y no cambió nada, con
razón: **un `ListView` vertical sin `padding` explícito no usa cero**.
`BoxScrollView.build` le inyecta el padding vertical del `MediaQuery` ambiente
(barra de estado/notch arriba, barra de gestos abajo), y esa pantalla no está
dentro de un `SafeArea`. Medido en un test desechable: un `ListView` con 100 px
de contenido mide **172 px** bajo un `MediaQuery` de padding 48/24.

Arreglo: `padding: EdgeInsets.zero`. **El mismo patrón existe en otros ~10
`ListView` con `shrinkWrap` de la app**; no se tocaron para no cambiar
espaciados sin verificación visual, pero conviene revisarlos.

### 6.4 Canciones que se quedan cargando en el primer intento

No se pudo reproducir (le pasó a 2 canciones), así que **no se parcheó a
ciegas** — la lección de §1. Lo que sí se encontró leyendo el código es un
fallo demostrable e independiente de la causa raíz:

El spinner de la UI se dibuja **exactamente** con `processingState` en
`loading`/`buffering`, y `setUrl` emite `loading` nada más empezar. Cualquier
fallo posterior dejaba la UI girando para siempre: el `catch` del controlador
registraba el error pero **nunca sacaba al motor de `loading`**. Y si el future
de carga del motor no completa (que es justo lo que describe el síntoma), ni
siquiera se llegaba al `catch`.

Correcciones, todas dentro del **único** camino de reproducción del controlador
— sin vigilantes ni reintentos en segundo plano (§2.1):

1. El fallo de carga devuelve el motor a `idle`, así el spinner se apaga y
   aparece un aviso. Con estado `idle` y pista actual, pulsar Reproducir rehace
   `playCurrent()` entero: el reintento lo decide el usuario, no un temporizador.
2. Techo de espera de 30 s sobre la carga (`setUrl`/`setLocalSource`). Una carga
   normal tarda menos de un segundo. Efecto secundario bueno: `skipToNext()`
   sostiene su guard mientras espera a `playCurrent()`, así que una carga
   colgada dejaba el botón "siguiente" muerto **para siempre**; ahora como
   mucho 30 s.
3. Logs que discriminan: `URL resuelta` → `Fuente cargada por el motor en Xms`
   → `Comando play() entregado`. Si en el próximo caso aparece el primero pero
   no el segundo, el que no completa es el future de carga del motor; si
   aparecen los tres y aun así no suena, el motor aceptó el comando y no llegó
   a bufferear. Son investigaciones opuestas (§5.3).

### 6.5 Restaurar sesión con contexto de playlist y cola manual

Verificado con un round trip real por JSON: el controlador **ya** guardaba y
restauraba bien `activeContextId`, cola manual, automática y contexto
original. Lo que fallaba era la **escritura en disco**:

`saveSession` hacía `writeAsString` directo sobre el archivo final (lo trunca y
después lo llena) y **sin ninguna serialización**, mientras el controlador lo
llama en cada play/pause/next/cambio de cola. Dos escrituras solapadas podían
dejar un JSON a medias, y `loadSession` no distingue eso de "no hay sesión":
devuelve `null` y **se pierde la sesión entera**. Un test con 50 guardados
concurrentes contra el código anterior termina con la posición **49**, no la
50: ni siquiera respetaba el orden.

Arreglo: escritura a un temporal + `rename` atómico, y *single-flight con
coalescing* (nunca dos escrituras a la vez; una ráfaga se colapsa en dos).

### 6.6 Guardado periódico de la posición

Ahora la sesión se persiste cada 5 s mientras suena algo, enganchado al tick
que el motor ya emite (sin temporizadores propios ni escrituras al motor).

Y la causa de que **la barra apareciera en 0** aunque el audio sí arrancara en
el segundo correcto: `_restoreSession` deja la posición en el estado, pero el
motor sigue emitiendo su estado en reposo (posición 0, sin reproducir) y el
siguiente tick la pisaba. La ventana de supresión está atada al **id de la
pista dueña** y solo aplica mientras el motor reporte posición 0 sin
reproducir, así que no puede filtrarse a la siguiente pista — exactamente la
forma que exige §2.3.

### 6.7 Matching de YouTube: la hipótesis de las palabras clave era falsa

Ver `docs/fuentes_youtube_y_matching.md` (documento nuevo, que además explica
de una vez cuándo se usa YouTube y cuándo YouTube Music).

Resumen: el vídeo instrumental que sonó en lugar de "Ladders" de Mac Miller
**se titula literalmente "Ladders - Mac Miller (Official Audio)"**. No dice
"instrumental" ni "karaoke" en ninguna parte, así que ninguna lista de términos
indeseados podía atraparlo. Lo que lo distingue del master real es el canal.

Con los pesos anteriores el impostor ganaba de forma sistemática: `official`
(+30) y `audio` (+30) sumaban por separado, contra +30 del canal `- Topic`.
Escribir dos palabras de marketing valía el doble que ser el master del sello.
Ahora los términos del título suman **un solo bonus acotado** y el canal
autorizado vale +120 — más que la duración exacta — porque es la única señal
que un re-subidor no puede falsificar.

### 6.8 Portada de "Mr. Brightside": no es un bug nuestro

Verificado contra la API en vivo. Deezer devuelve la entrada de la
recopilación "Nu Rock" como resultado principal (`rank` 905.448, el más alto),
y **también** en `/artist/897/top` y al buscar por el ISRC de la grabación. La
versión de *Hot Fuss* no aparece ni en los primeros ocho resultados.

Y no hay señal barata para detectarlo: el `album` embebido en `/search` solo
trae `id`, `title` y portadas. Hay que pedir `/album/{id}` aparte para ver que
su artista es "Varios Artistas" — y ahí `record_type` vale `"album"`, **no**
`"compilation"`, así que ese campo tampoco sirve. Corregirlo exigiría varias
peticiones por pista contra una API limitada a 50 cada 5 s, para cambiar una
miniatura. **No se implementó**; el detector correcto, si algún día se hace, es
`album.artist.id == 5080`.

### 6.9 Inicio vacío en el arranque en frío (Android) — la regresión recurrente

Este fallo volvió al menos tres veces. La causa de que **reaparezca** es que el
arreglo original (`startup_retry.dart`, §4) dependía de un presupuesto de
reintentos demasiado corto para el dispositivo, así que basta con que el
arranque se vuelva un poco más lento (o el teléfono un poco más ocupado) para
que vuelva a fallar. No era un arreglo que se rompiera: era un arreglo
calibrado justo en el límite.

El dato que lo explica: el fallo de DNS del arranque en Android **vuelve en
milisegundos** (`Failed host lookup`), no espera al `connectTimeout` de 10 s de
Dio. Con 3 intentos y esperas de 600 ms y 1200 ms, los tres se agotaban en
**menos de 2 segundos**. En un dispositivo que tarda más de eso en tener DNS
utilizable, Inicio quedaba en "No pudimos cargar el contenido" en **todos** los
arranques, y solo el botón Reintentar lo sacaba de ahí.

Correcciones:

1. El presupuesto se cuenta en **tiempo de reloj** (15 s), no en número de
   intentos — así deja de depender de adivinar cuánto tarda un fallo. Con tope
   de espera entre intentos (2 s) para que el backoff exponencial no se coma el
   presupuesto en dos esperas largas.
2. Corte por `shouldRetry`: si `isConnectedProvider` dice que no hay interfaz
   de red, se relanza de inmediato sin quemar el presupuesto — el estado "Sin
   conexión" sigue apareciendo al instante. Solo se **lee** ese provider,
   nunca se modifica (§2.2).
3. Inicio se recarga solo en la transición offline → online, en vez de esperar
   a que el usuario pulse Reintentar.

Test de regresión: una acción que solo funciona a partir de los 2.5 s de reloj.
Con los valores anteriores falla; con el presupuesto nuevo pasa.
