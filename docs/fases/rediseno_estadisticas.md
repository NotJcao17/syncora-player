# Rediseño de Estadísticas

Leer antes de tocar `lib/features/stats/`, `listening_history`, el registro de
escuchas de `syncora_player_controller.dart` o el agregado mensual de Supabase.

## Punto de partida

Síntomas reportados: "escucho 1 hora y aparece una cantidad diferente",
"escucho una canción y no aparece", "aparecen cosas distintas en 2
dispositivos", "no se guardan los géneros".

El diagnóstico **no** se hizo leyendo código nada más: se bajaron las 290
filas reales de `listening_history` del proyecto de desarrollo y se
analizaron. Eso es lo que convirtió cinco hipótesis en una causa dominante
medida.

## Hallazgos verificados (H-S1 a H-S11) — no volver a descubrirlos

### H-S2 · La causa dominante, medida sobre datos reales

**197 de 290 filas (68 %) estaban congeladas en 25-35 s**, exactamente el
valor del umbral con el que se inserta la escucha. Agrupando por sesión
(huecos > 20 min):

- Todo lo anterior al **2026-08-30 20:00 UTC** estaba congelado al 100 % (176
  filas): datos previos al fix de la "ronda 3", ya muertos.
- Después de ese fix, **14 de 20 sesiones seguían terminando con su última
  pista congelada**.

Causa: la duración real solo se escribía al cambiar de pista o en `dispose()`,
y `dispose()` casi nunca corre — el SO mata el proceso cuando deslizas la app
en Android o cierras la ventana en Windows.

**Fix:** volcado periódico cada 15 s (`_flushListenProgress`,
`_listenFlushInterval`). Lo peor que se pierde ahora son los últimos 15 s.

### H-S1 · Minutos perdidos por ticks de posición tardíos

`_trackListenProgress` descartaba **entero** cualquier avance de posición
mayor a 3 s, para filtrar seeks. Pero un tick que llega tarde (pantalla
apagada en Android, o simplemente la cadencia distinta de `media_kit` en
Windows frente a `just_audio` en Android) produce un delta grande que es
escucha real. Se perdía tiempo, y **de forma distinta en cada plataforma** —
parte de por qué los dos dispositivos nunca coincidían.

**Fix:** el criterio correcto no es "el delta es pequeño" sino "el delta cabe
en el tiempo de reloj que pasó de verdad". Vive en `naturalListenDelta`
(`lib/features/player/listen_tracking.dart`), como función pura con tests de
mesa. Un seek de 0:10 a 3:00 salta 2:50 en 200 ms de reloj y se sigue
rechazando; un tick tardío de 12 s ahora cuenta.

### H-S3 · El dedupe fusionaba escuchas de otro dispositivo

`findRecentEntryForTrack` reutiliza la fila de una escucha reciente en vez de
crear otra. No distinguía las filas que había bajado `_pullRemoteHistory`: si
escuchabas un tema en el PC y lo ponías en el móvil cinco minutos después, el
móvil **editaba la fila del PC** y subía la suma. Una fila inflada, una
escucha desaparecida, y un resultado que dependía del orden de los syncs.

En los datos reales solo se había manifestado 1 vez (poco uso simultáneo de
los dos aparatos), pero es corrupción de datos, no un problema de
presentación.

**Fix:** columna `fromRemote` en Drift (schema v10); el dedupe solo mira filas
propias.

### H-S4 · El push era fila a fila

`getUnsyncedHistory(limit: 100)` + un `upsert` por fila + `break` al primer
error. Subir 200 escuchas acumuladas eran 200 viajes de red.

**Fix:** lotes de 200 en una sola petición (`insertListeningHistoryBatch`), sin
tope de 100, con deduplicación previa dentro del lote — dos filas con la misma
clave de conflicto harían fallar el lote entero
("cannot affect row a second time").

### H-S5 · La lectura se truncaba en silencio a 1000 filas

`fetchEntriesSince` bajaba las filas crudas sin `limit` ni `order`: PostgREST
aplica su `max-rows` (1000) y devolvía un **subconjunto arbitrario**. Con 30
días de uso intenso la vista Mensual perdía datos sin avisar.

**Fix:** RPC `get_listening_stats` — ver abajo.

### H-S6 · El género era siempre NULL

**0 de 290 filas** tenían género, y no por descuido: Deezer **no devuelve
género en ningún endpoint de canción** (`/search`, `/track/{id}`,
`/artist/{id}/top`). Solo `/album/{id}` lo trae, en `genres.data[0].name`
(verificado en vivo: `/album/302127` → `"Electro"`).

**Fix:** `GenreBackfillService` resuelve por **álbum** en segundo plano, una
petición por álbum nuevo, cacheada sin caducidad en `AlbumGenreCache` (schema
v11). Sirve igual para escuchas nuevas y para el relleno retroactivo. Se
cachea también el resultado vacío, para no reintentar siempre.

### H-S7 · Redondeo inconsistente

Dart hacía `ceil()` por cada artista y cada canción; el SQL hacía división
entera. La suma de los minutos por artista no daba el total, y el mismo mes
cambiaba de número al pasar de "crudo" a "agregado".

**Fix:** todo se guarda, suma y transporta en **milisegundos**. Se redondea
una sola vez, en `formatListeningTime`.

### H-S8 · `user_stats_monthly` no se llenaba del todo

El cron era mensual y solo agregaba meses ya **cerrados**, así que el mes en
curso no aparecía nunca en las vistas largas.

**Fix:** la función recalcula también el mes actual (es idempotente) y el cron
pasa a diario (`10 5 * * *`).

### H-S9 · Descartado

Se sospechaba que faltara el índice único de dedupe y que el `upsert` con
`onConflict` estuviera fallando siempre. **Verificado: las 12 migraciones
estaban aplicadas.** No era esto.

### H-S10 · Las reproducciones se perdían en periodos largos

`user_stats_monthly` solo guardaba `{id, minutes}`. **Fix:** ahora guarda
`plays` por entidad, `total_plays`, `top_albums` y un histograma hora×día.

### H-S11 · No existía serie temporal

Nada guardaba minutos por día/semana, así que no había de dónde sacar un
gráfico. **Fix:** el RPC la devuelve ya agrupada.

## Arquitectura resultante

### Por qué un RPC y no bajar filas (plan free)

| | Bajar filas | RPC |
|---|---|---|
| Vista de 30 días | ~3000 filas ≈ 200 KB | ~5 KB |
| Vista de 12 meses | hay que paginar, varias MB | ~5 KB |
| Egress con 250 usuarios | >1 GB/mes | ~30 MB/mes |

Serializar 3000 filas a JSON tampoco es más barato en CPU que agruparlas en
Postgres. El RPC gana en las dos métricas.

### Retención y ventanas

El historial crudo se sigue podando a **90 días** (decisión del usuario: plan
free, 500 MB de base). Eso obliga a partir las ventanas en dos:

- **7 d / 30 d / 3 meses** → exactos, desde `listening_history`, vía RPC.
- **6 m / 12 m / Todo** → desde `user_stats_monthly`.

**Limitación asumida y visible en la UI:** en las ventanas largas los
*totales* son exactos, pero los *tops* son aproximados — cada mes guarda solo
sus 30 mejores, así que un artista que queda siempre en el puesto 35 no
aparece. El snapshot sale con `topsAreApproximate: true` y el panel lo dice.

### Zona horaria

El RPC recibe `p_tz_offset_minutes`. Los cortes por día/semana/mes tienen que
caer en la medianoche **local** del usuario o el gráfico sale corrido un día.
Se pasa el desfase en minutos y no un nombre IANA porque es lo que Dart sabe
dar sin dependencias.

`StatsCalculator` (modo local) agrupa por el día local del dispositivo, así
que produce los mismos buckets de calendario. El test de paridad compara
fechas de calendario, no instantes, justamente por esto.

### Doble cálculo, y por qué está bien

El cálculo existe dos veces: en Postgres (con cuenta) y en Dart (modo local,
que no tiene servidor al que preguntar). **`stats_calculator_test.dart`
contrasta los dos contra la respuesta literal del RPC** sobre los mismos
datos: si alguien cambia uno y no el otro, el test lo caza.

## Verificación hecha contra Postgres real

`aggregate_monthly_listening_stats()` **nunca había corrido contra Postgres**
(estaba en la lista de pasos manuales pendientes). Ahora sí: se ejecutó, la
sintaxis `LEFT JOIN LATERAL` funciona, y produce los tops con `plays`.

`get_listening_stats` se probó de punta a punta creando un usuario de prueba
desechable, sembrando 5 escuchas deterministas, llamando al RPC con su JWT
real y borrando el usuario después. Todos los números cuadraron, incluidos el
desfase horario (una escucha a las 02:00Z pasa del día 19 al 18 en UTC-6) y el
aislamiento por RLS.

`stats_health()` (solo `service_role`) responde de un vistazo si `pg_cron`
sigue instalado, si el job existe y cuándo corrió. Existe porque el scheduling
vive en un bloque `DO` que se traga los errores a propósito, así que "la
migración no falló" no probaba nada.

## Limpieza de datos hecha

Se borraron las **173 filas anteriores al 2026-08-30 20:00 UTC** (el 100 %
congeladas en 30 s, previas al fix de la ronda 3) y se recalculó el agregado
de agosto. Quedan 117 filas, todas posteriores al fix. Autorizado
explícitamente por el usuario: solo había cuentas de desarrollo.

## Pendiente

- **Pruebas en dispositivo** (Android y Windows) del dashboard y de la
  medición: reproducir una hora conocida y contrastar contra la pantalla.
- El **relleno de géneros corre en la app**, no desde el servidor: hasta que
  no se abra la app (arranque o pantalla de Estadísticas) las 117 filas
  siguen sin género. 25 álbumes por corrida.
- Queda sin resolver, a propósito, que un cierre abrupto pierda hasta 15 s de
  la pista en curso. Bajar el intervalo es una constante
  (`_listenFlushInterval`), pero cada volcado es una escritura en Drift.
