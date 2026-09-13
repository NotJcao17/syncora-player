# Plan — Tercera ronda de correcciones post-Fase 7

Estado: **plan aprobado pendiente de ejecución**. Fuente de verdad del progreso de esta ronda
(marcar `[x]` a medida que se cierra cada punto y comitear seguido, igual que en la Fase 7).

Baseline al escribir el plan: `flutter analyze` limpio, rama `master` en `1cdf556`.

Rondas anteriores: `docs/fases/correcciones_qa_post_fase_7.md` (§1-§6). Las reglas de método de
su §5 aplican aquí igual, en especial: **revertir antes que apilar**, **nada escribe en el motor de
audio fuera del camino de reproducción del controlador**, **sin banderas globales que alguien deba
acordarse de limpiar**, y la puerta de calidad son tres cosas (`flutter analyze` + `flutter test` +
compilar Android).

---

## Diagnóstico previo (hecho antes de escribir el plan)

Cinco de los fallos reportados tienen **causa raíz común o ya confirmada por lectura de código**.
Se documentan aquí para no volver a descubrirlos:

### H-R3-1 · No existe manejo de foco de audio en Android

`audio_session` está en `pubspec.lock` solo como dependencia **transitiva** de
`just_audio`/`audio_service`, y **no se usa en ninguna parte de `lib/`**: no hay
`AudioSession.instance.configure(...)`, ni suscripción a `interruptionEventStream`, ni a
`becomingNoisyEventStream`. `just_audio` no gestiona interrupciones por su cuenta — es
responsabilidad de la app.

Explica de golpe: la alarma que deja la música trabada, la interrupción por una historia de
Instagram que nunca reanuda, "de repente se detuvo el audio", y que el reproductor de pantalla de
bloqueo se cierre tras la interrupción.

### H-R3-2 · Se publica `idle` entre pista y pista

`_playCurrentInternal` hace `await _engine.stop()` antes de cargar la siguiente fuente (salvo en el
camino de crossfade). Eso emite `processingState: idle`, que `SyncoraAudioHandler._publishPlaybackState`
traduce tal cual a `AudioProcessingState.idle` en el `playbackState`. `audio_service` interpreta
`idle` como "ya no hay sesión activa" y **suelta el foreground service**.

Explica: (a) "el reproductor de pantalla de bloqueo desaparece un segundo y vuelve" — literal, la
notificación se destruye y se recrea; (b) —hipótesis fuerte— los **2-3 minutos de silencio con la
pantalla apagada**: sin FGS vivo, Android congela el proceso (Doze/App Standby) justo mientras el
isolate de extracción está resolviendo la URL de la pista siguiente, y no lo descongela hasta el
siguiente evento; (c) "la música se detuvo y al volver a entrar a la app se reanudó sola", que es
exactamente la firma de un proceso congelado que se reanuda al traer la app al frente.

### H-R3-3 · `setQueue` en shuffle solo mezcla la cola de la playlist

```dart
final rest = tracks.sublist(clampedStart + 1);
final newAuto = _state.shuffle ? (List<SyncoraTrack>.from(rest)..shuffle()) : rest;
```

En modo normal descartar lo anterior al índice es correcto. **En shuffle no**: tocar la pista #50
de una playlist de 60 deja una cola automática de 10, no de 59. Las 49 anteriores no vuelven a
sonar en toda la sesión.

Explica directamente: *"solo se reproducen ciertas canciones, no se reproduce el resto de la
playlist (que iba antes de esas canciones) y empieza antes la cola de radio infinita"* — con 10
pistas en cola, el umbral de radio (`autoQueue.length <= 5`) se cruza a la cuarta canción.

### H-R3-4 · Paleta y "me gusta" del reproductor a pantalla completa solo se calculan en `initState`

`_extractPalette()` y `_checkIsLiked()` se llaman **únicamente** en `initState` de
`PlayerFullscreenScreen`. Con la pantalla abierta, cambiar de pista no recalcula ninguno de los
dos.

Explica: *"la canción tenía portada roja y el fondo salía completamente verde, la canción previa o
siguiente era del álbum brat"* — el fondo se quedó con el color de la pista que sonaba cuando se
abrió la pantalla. El mismo bug deja el corazón desincronizado.

### H-R3-5 · El historial cuenta una escucha por cada arranque de la pista

`_beginListenTracking` resetea el acumulado **en cada intento de reproducción** y `_recordListenEntry`
hace un `INSERT` nuevo en cuanto se cruza el umbral D-16. No hay ninguna deduplicación. Por tanto:
retroceder a una pista ya contabilizada y volver a pasar el umbral → **segunda fila**; escuchar
media canción, cerrar la app, volver y terminarla → **dos filas** (con el agravante de que, tras el
reinicio, la posición restaurada es >0 pero el acumulado arranca en cero, así que basta con
escuchar 30 s más).

Explica el punto *"en el historial de reproducción aparecen canciones 2 veces"* y confirma la
sospecha del usuario sobre las estadísticas.

---

## Metodología de esta ronda

- **Bundles**, no fases. Cada bundle se implementa, se valida (`flutter analyze` + los tests del
  área tocada) y se comitea. `flutter test` **completo** una sola vez por bundle, justo antes de
  comitear. Nunca dos invocaciones de `flutter test`/`analyze`/`build` en paralelo (lock real sobre
  `sqlite3.dll`).
- **Orden:** A → B → C → D → E → F. A y B son los que pueden romper cosas que funcionan; van
  primero y con más cuidado. D/E/F son de UI y bajo riesgo.
- **Revisión independiente (subagente aparte)** solo para **Bundle A y Bundle B** — tocan el motor
  de audio, la cola dual (D-1) y la sesión persistida, que es exactamente la categoría de "riesgo
  real" definida en `CLAUDE.md`. C, D, E y F los revisa el orquestador leyendo el diff.
- **Compilar Android (`gradlew assembleDebug`)** al cerrar el Bundle A, porque toca manifiesto y
  recursos `drawable/`, que `analyze`/`test` no ven (§2.5 de la ronda anterior).
- Las pruebas en dispositivo las hace el humano al final de cada bundle de audio; el agente no
  parchea a ciegas síntomas que no pueda reproducir (§6.4 de la ronda anterior).

---

## Bundle A — Reproducción en Android (crítico)

Objetivo: que la app se comporte como cualquier reproductor serio ante interrupciones y pantalla
apagada. Es el bundle con más impacto y el más delicado.

- [x] **A1 · Sesión de audio e interrupciones.** Promover `audio_session` a dependencia directa
      (`^0.2.4`, ya en el lock). Un servicio nuevo `lib/features/player/audio_focus_service.dart`:
  - `AudioSession.instance.configure(AudioSessionConfiguration.music())` una sola vez al arrancar.
  - `interruptionEventStream`: al comenzar, `duck` → bajar volumen; `pause`/`unknown` → pausar
    recordando **si estábamos sonando**. Al terminar, restaurar volumen o reanudar **solo si la
    pausa la causó la interrupción** (nunca si el usuario pausó a mano en medio).
  - `becomingNoisyEventStream`: pausar al desconectar auriculares/Bluetooth (comportamiento
    estándar; hoy la música sigue sonando por el altavoz).
  - Se conecta al controlador desde `player_providers.dart`, **solo Android** (`Platform.isAndroid`),
    y llama exclusivamente a `controller.play()/pause()/setVolume()` — nunca al motor directo
    (§2.1 de la ronda anterior).
  - Test: un doble de sesión que emita eventos de interrupción y verifique la máquina de estados
    (pausa por interrupción → reanuda; pausa del usuario durante la interrupción → NO reanuda).

- [x] **A2 · No soltar el foreground service entre pistas** (H-R3-2). El controlador expone
      `bool get isPreparingPlayback`, puesto en `true` al entrar a `_playCurrentInternal` y
      liberado en un `finally` (acotado de por sí por `_engineLoadTimeout` de 30 s, así que no
      puede quedarse pegado — cumple la regla de §2.3). `SyncoraAudioHandler._publishPlaybackState`
      mapea `idle` → `loading` mientras esa bandera esté activa **y** haya `currentTrack`.
      Efecto esperado: la notificación deja de parpadear y el proceso no se congela a mitad de
      transición.
  - Test: el handler publica `loading`, nunca `idle`, durante una transición simulada.

- [x] **A3 · Un reintento acotado ante fallo de carga del motor.** `_failPlaybackLoad` hoy muestra
      *"No se pudo iniciar X"* al primer fallo. Se añade **un** reintento inmediato dentro del mismo
      camino de reproducción (nada de vigilantes en background) antes de rendirse. La política
      403/red existente (`RetryPolicy`, máx. 1 reintento, Pitfall #11/#14) no se toca.

- [x] **A4 · Salida para "canción no disponible" sin reiniciar la app.** Hoy `unavailableTrackIds`
      es de sesión y `track_tile` bloquea el tap con *"No disponible en este dispositivo"* sin
      forma de reintentar. Se añade `controller.clearUnavailable(trackId)` y se cambia el tap sobre
      una pista marcada por "limpiar marca + reintentar una vez", en vez del toast muerto.
      (D-21 se mantiene: el marcado sigue siendo de sesión y no se persiste.)

- [x] **A5 · Paleta y corazón del reproductor a pantalla completa** (H-R3-4). `ref.listen` sobre
      `currentTrackProvider` para recalcular ambos al cambiar de pista, con la respuesta de
      `PaletteGenerator` atada al id de la pista que la pidió (descartar si llegó tarde). Se
      aprovecha para usar la portada ya cacheada en vez de un `NetworkImage` crudo.

- [x] **A6 · Ícono de aleatorio con estado en la notificación.** `_shuffleControl` es hoy una
      constante con `drawable/ic_shuffle` fijo. Pasa a getter que alterna entre `ic_shuffle` (activo)
      e `ic_shuffle_off` (nuevo `drawable/` a crear, variante tachada/apagada), igual que ya hace
      `_favoriteControl` con el corazón.

- [x] **A7 · Portadas que dejan de verse tras un rato en el móvil.** Diagnóstico previsto: cuando
      una carga falla (típicamente DNS no listo en frío, §6.9 de la ronda anterior),
      `CachedNetworkImage` se queda en `errorWidget` para ese widget hasta que se reconstruya.
      Corrección acotada: un reintento único y diferido dentro de `TrackCoverImage`, y re-emisión en
      la transición offline→online. **Si al medirlo resulta que la causa es otra, se documenta y no
      se parchea a ciegas.**

**Gate del bundle:** `flutter analyze` + `flutter test` + `gradlew assembleDebug` + revisión
independiente (subagente) + tanda de pruebas en dispositivo del humano.

---

## Bundle B — Cola, shuffle y sesión

Toca D-1 (cola dual) y la sesión persistida: riesgo real, revisión independiente obligatoria.

- [x] **B1 · Shuffle desde un índice mezcla la playlist completa** (H-R3-3). En `setQueue`, si
      `shuffle` está activo, la cola automática se arma con **todas** las pistas del contexto menos
      la que arranca, mezcladas — no con `sublist(startIndex + 1)`. Sin shuffle, el comportamiento
      actual se mantiene intacto.
  - Test de regresión: `setQueue(60 pistas, startIndex: 50, shuffle: true)` deja 59 en
    `autoQueue`, no 9.

- [x] **B2 · Restaurar sesión: continuidad exacta.**
      **Decisión del usuario (consultada al aprobar este plan): continuidad exacta.** Al reabrir la
      app, la cola automática se restaura tal cual quedó — mismo orden aleatorio, mismas canciones,
      incluidas las de radio que ya estuvieran anexadas. Es lo que hace Spotify al reanudar.

      Esto **ya resuelve** la queja de *"mete canciones recomendadas en vez de las de la playlist"*
      una vez corregido B1: el lote de radio siempre se anexa **al final** de la cola, así que con
      la playlist completa en `autoQueue` las recomendadas no pueden colarse antes. El síntoma
      venía de H-R3-3 (la cola tenía 10 pistas en vez de 59), no de la restauración.

      **Red de seguridad implementada y luego retirada tras la revisión independiente.** La primera
      versión repoblaba la cola desde el contexto cuando la restaurada no conservaba ninguna pista
      de él, para reparar sesiones guardadas por versiones afectadas por H-R3-3. La revisión
      encontró que esa misma condición la cumple un caso legítimo: **el usuario que vacía la cola a
      mano**. Deslizar para eliminar dejaba `autoQueue` sin contexto, y al siguiente arranque se le
      devolvían todas — deshaciendo en silencio una acción explícita, en cada reinicio. Distinguir
      ambos casos exigiría persistir "qué quitó el usuario a mano" (estado nuevo en
      `PlayerSessionData`, invalidando las sesiones guardadas) para atender un problema de
      migración puntual que además se arregla solo en cuanto el usuario vuelve a tocar una
      playlist. No compensa: se retiró, con la justificación escrita en el propio controlador.

  - Consecuencia aceptada: *"al reiniciar en random vuelven a tocar las mismas canciones"* se queda
    como está, a propósito — reanudar significa continuar, no barajar de nuevo. Quien quiera otra
    mezcla tiene **B4 (Regenerar cola)**.

- [x] **B3 · La radio solo entra cuando el contexto se agotó.** El umbral actual
      (`autoQueue.length <= 5`) pasa a contar **solo pistas del contexto original** que quedan en
      `autoQueue`. Con B1+B2 el efecto práctico es el que pidió el usuario: la cola infinita empieza
      cuando termina la última de la playlist (modo normal) o cuando ya sonaron todas (modo
      aleatorio). El lote se sigue anexando **al final**, así que nunca se cuela antes de una pista
      de la playlist.

- [x] **B4 · Regenerar cola.** Acción nueva `controller.regenerateAutoQueue()` + entrada en la
      barra de la vista de Cola, visible solo cuando hay contexto activo o radio habilitada:
      rehace la cola automática desde el contexto (remezclando si shuffle) y descarta el bloque de
      radio vigente. **Nunca toca la cola manual** (D-2) ni la pista sonando.

- [x] **B5 · Reordenar la cola en móvil.** Causa probable: el `VerticalDragGestureRecognizer` de
      `showModalBottomSheet` (`enableDrag: true` por defecto) gana la arena contra el
      `ReorderableDragStartListener` del asa. Corrección: `AppBottomSheet.show` acepta `enableDrag`
      y la hoja de la cola lo pasa en `false` (se cierra por el botón/gesto de fondo, no
      arrastrando la lista). Verificación visual en Chrome con viewport móvil antes de dar por
      bueno; si el gesto sigue perdiendo, se pasa la cola a ruta de pantalla completa en móvil.

- [x] **B6 · Deslizar a la izquierda para eliminar en la cola.** El `Dismissible` ya existe; queda
      verificar que funciona una vez resuelto B5 (hoy compite con el mismo gesto) y que el índice
      que se pasa a `removeFromQueue` sigue siendo válido tras el `onDismissed`.

**Gate del bundle:** `flutter analyze` + `flutter test` + revisión independiente (subagente).

---

## Bundle C — Historial y estadísticas

- [x] **C1 · Deduplicar escuchas** (H-R3-5). Antes de insertar, `_recordListenEntry` consulta la
      última entrada de esa pista: si es de hace menos que `max(duración de la pista, 10 min)`, se
      **acumula sobre esa fila** (`updateListenedDuration`) en vez de insertar una nueva.
      Cubre los dos casos reportados (retroceder tras cruzar el umbral; partir una canción en dos
      sesiones de app) sin perder los minutos escuchados y sin confundir una repetición real a las
      horas con un duplicado.
  - Método nuevo en `ListeningHistoryDao` + test unitario de la ventana (dentro → acumula, fuera →
    fila nueva).
  - Nota: solo corrige de aquí en adelante; el historial ya duplicado se deja como está.

---

## Bundle D — Biblioteca

- [x] **D1 · Ordenar playlists.** Selector con tres criterios: *escuchadas recientemente*,
      *agregadas recientemente*, *alfabético*. Requiere columna nueva `lastPlayedAt` en la tabla
      `Playlists` de Drift → **migración de esquema v6 → v7** (`addColumn`, nullable, sin tocar
      Supabase: "última escucha" es razonablemente un dato del dispositivo). Se escribe desde el
      `setQueue` con `activeContextId` de tipo `playlist_*`. La preferencia de orden se guarda
      local.

- [x] **D2 · Vista lista / cuadrícula.** Toggle en la cabecera de Biblioteca; en cuadrícula,
      portada grande + título debajo (estilo Spotify), reusando `PlaylistCoverWidget`. Preferencia
      persistida local. Aplica a Playlists y Álbumes.

- [x] **D3 · Indicador de la playlist sonando.** En la fila/tarjeta cuya `playlist_<id>` coincida
      con `activeContextId`, marca visual (título en color de acento + ícono de onda). Sin
      peticiones ni streams nuevos: sale de `playerStateProvider.select((s) => s.activeContextId)`.

- [x] **D4 · Buscador dentro de la playlist.** El botón de lupa del detalle de playlist hoy hace
      `context.push('/search')`. Pasa a abrir un campo de filtro **local** sobre las pistas de esa
      playlist (título / artista / álbum), sin llamadas de red. El buscador existente de "Agregar
      canciones" (que sí va a Deezer) se mantiene aparte, sin cambios.

- [x] **D5 · Sin números de pista en móvil.** `TrackTile` ya cambia de layout cuando `index` es
      `null` (muestra portada con overlay de play en vez del número). Pasar `index: isDesktop ? i : null`
      en el detalle de playlist. Revisión visual antes de darlo por bueno.

---

## Bundle E — Reproductor y detalles de UI

- [x] **E1 · Mini barra de progreso en el mini reproductor móvil.** Franja de 2 px pegada al borde
      inferior del contenedor, sin interacción (no clickeable), alimentada por
      `playerStateProvider.select` de posición/duración para no reconstruir el resto de la barra.

- [x] **E2 · Menú de 3 puntos completo en el reproductor a pantalla completa.** Hoy tiene solo
      *Reproducir a continuación* y *Agregar a la cola*. Pasa a reusar el juego completo de
      `TrackContextMenu` (ir al artista, ir al álbum, agregar a playlist, me gusta, descargar,
      compartir, buscar otras versiones), respetando el gateado por `canEditProvider`.

- [x] **E3 · Posición del aviso de "me gusta" desde los 3 puntos.** `AppToast` calcula el margen
      inferior con ramas distintas según pantalla y presencia de mini reproductor; desde la hoja de
      3 puntos cae en una rama que no corresponde a lo que se ve. Se unifica el cálculo (una sola
      fuente para la altura de mini reproductor + barra de navegación) y se verifica en móvil que
      el aviso salga en el mismo sitio desde ambas entradas.

- [x] **E4 · Búsqueda profunda pegada al borde superior en móvil.** La hoja se abre con
      `height: 0.85 * screenHeight` y `top: 20`, sin `SafeArea` ni asa. Se alinea con el resto de
      hojas de la app (asa, respeto del notch, tope de altura que descuente el área segura).

---

## Bundle F — Deezer y metadatos

- [x] **F1 · Separar álbumes de sencillos en la discografía.** `/artist/{id}/albums` devuelve
      `record_type` (`album` / `single` / `ep` / `compilation`) y hoy el modelo `DeezerAlbum` lo
      descarta. Se añade el campo y un filtro en la pantalla de artista (píldoras: *Álbumes* /
      *Sencillos y EP* / *Todo*). **Coste cero en peticiones**: el dato ya viene en la respuesta que
      se pide hoy.

- [x] **F2 · Más canciones populares del artista.** `/artist/{id}/top` sin `limit` devuelve **5**
      (no 10 — ya está confirmado contra la API en vivo y documentado en `getArtistTopTracksExpanded`).
      Se pasa a pedir `limit: 10` en la carga inicial, mostrar 5 y revelar las otras 5 con
      *Mostrar más*, **sin segunda petición**. Detalle técnico y respuesta a la pregunta del
      usuario, más abajo.

- [x] **F3 · Preferir la versión de álbum sobre el sencillo.** Desempate barato en `SearchRanking.rankTracks`:
      penalización pequeña y acotada cuando el nombre del álbum del resultado coincide con el
      título de la pista (firma típica del sencillo) **y** existe otro candidato del mismo artista
      con el mismo título base. Es un desempate de unos pocos puntos sobre una escala de ~200, así
      que solo mueve la aguja entre candidatos prácticamente idénticos.
      **No toca `YtSearchMatcher`** (el matcher de YouTube que costó la ronda anterior) ni el
      importador CSV: es exclusivamente el ranking de metadatos de Deezer.
      Si en las pruebas resulta que cambia resultados que hoy son correctos, se revierte — no vale
      la pena arriesgar algo que funciona por una miniatura y un nombre de álbum (§6.8 de la ronda
      anterior llegó a la misma conclusión para un caso vecino).

---

## Respuesta a la pregunta abierta: ¿cuántas canciones populares se pueden traer?

- `GET /artist/{id}/top` **sin** `limit` devuelve **5** resultados, no 10.
- Con `?limit=N` la API sí devuelve más: el proyecto ya lo usa con `limit: 100` en
  `getArtistTopTracksExpanded` (búsqueda de colaboraciones, Fase D) y funciona contra la API real.
  Deezer pagina con `index`/`limit`, así que técnicamente se puede ir bastante más allá de 10.
- **Recomendación:** pedir **10** en la carga inicial, mostrar **5** y revelar el resto con
  *Mostrar más*. Es exactamente lo que pidió el usuario, y es la opción correcta también por coste:
  una sola petición, sin segundo viaje al pulsar el botón, y sin traer 100 filas que en el 95% de
  las visitas nadie va a mirar. Subirlo a 20-25 más adelante sería un cambio de un solo número si
  se quiere una lista más larga; pasar de ahí no aporta (el "top" deja de ser top y el rate limit de
  Deezer —50 peticiones / 5 s por IP— se comparte con el resto de la pantalla).

---

## Fuera de alcance de esta ronda (anotado, no se toca)

- Los pasos manuales de infraestructura pendientes de la Fase 7 (migraciones de Supabase, Edge
  Function, Auth Hook, `pg_cron`) — siguen siendo del humano.
- Fase 8 (§11 del Documento Maestro): OTA, carpetas, búsqueda por género, previews de 30 s,
  lanzamientos personalizados.
- Los ~10 `ListView` con `shrinkWrap` y sin `padding` explícito que arrastran el padding del
  `MediaQuery` (§6.3 de la ronda anterior). Se revisan si alguno da un síntoma concreto.

---

## Segunda tanda: correcciones de la ronda de pruebas en dispositivo

Lo que el usuario probó y devolvió. Solo se listan los puntos que hubo que tocar; el resto quedó
confirmado como correcto.

- [x] **Cola en móvil: reordenar y deslizar seguían sin funcionar, y encima ya no se podía
      cerrar.** `enableDrag: false` no era la solución — quitó la única forma de cerrar la hoja sin
      arreglar los gestos. La cola pasa a ser una **ruta a pantalla completa** en móvil (diálogo
      centrado en escritorio, como manda la directriz de UI): sin hoja modal no hay reconocedor de
      arrastre vertical envolviendo la lista, y el botón/gesto de atrás cierra. Además el asa de
      reordenar se mueve a la **derecha** y se desactiva el menú por pulsación larga dentro de la
      cola (`TrackTile.enableLongPressMenu`), que competía con el deslizar y el arrastrar.
- [x] **Crash al ir al artista desde el reproductor a pantalla completa**
      (`!keyReservation.contains(key)`). Causa real: **ningún `pageBuilder` del router pasaba
      `key: state.pageKey`**. Empujar una ruta del shell desde `/player` (que vive en el navegador
      raíz) dejaba el shell apilado dos veces con la misma clave nula. Corregido en las 13 rutas.
      Además, ir al artista/álbum desde el reproductor ahora lo **cierra antes** de navegar
      (`onNavigateAway`), que es lo que se espera y deja una pila coherente.
- [x] **Posición de los avisos.** Se abandonan las constantes: el shell **mide** su chrome inferior
      real (`MeasuredBottomChrome`) y publica el alto; avisos y aviso de "sin conexión" lo leen. Las
      rutas que tapan el shell (reproductor completo, pantalla de Cola) declaran
      `BottomChromeScope(hasChrome: false)` y sus avisos van pegados abajo — eso es lo que dejaba
      el aviso de "cola remezclada" flotando a media pantalla.
- [x] **Búsqueda profunda demasiado alta en móvil.** `useSafeArea: true` en la hoja. Calcularlo a
      mano con `MediaQuery.padding` desde dentro del `builder` no servía: ahí el padding superior
      ya viene consumido.
- [x] **Biblioteca sin botones de 3 puntos.** El menú se abre con click derecho (escritorio) o
      pulsación larga (móvil), en lista y en cuadrícula. Orden, cuadrícula e indicador de "sonando
      ahora" se extienden a **Álbumes** y **Descargados** (columna `SavedAlbums.lastPlayedAt`,
      esquema v8, también solo local). Las tres secciones comparten ahora los mismos constructores
      de fila y celda.
- [x] **Regenerar cola con el contexto agotado.** Ya no repone la playlist desde el principio:
      descarta la radio vigente y pide un lote nuevo. Reponerla se sentía raro con razón — estando
      en la última canción no quieres media playlist que acabas de escuchar.
- [x] **Sencillos y EP separados en la discografía.** Verificado contra la API en vivo: Deezer
      marca como `single` lanzamientos de hasta 3 pistas y como `ep` los de 4-5. No era un fallo de
      clasificación nuestro, pero meterlos bajo una píldora que decía "Sencillos" lo parecía.
- [x] **La app se cerraba tras usar Instagram/TikTok.** `androidStopForegroundOnPause: false`: con
      el default, pausar suelta el foreground service y la app queda como proceso de fondo
      corriente, candidata al *low memory killer*. El manejo de foco de A1 hizo mucho más frecuente
      ese camino, porque ahora sí se pausa cuando otra app toma el foco. Obliga a poner
      `androidNotificationOngoing: false` (hay un assert en `audio_service` que lo exige).
- [x] **Tooltip de las playlists en la barra lateral de escritorio:** quitado.
