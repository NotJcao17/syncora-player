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
