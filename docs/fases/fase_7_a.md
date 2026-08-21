# Syncora Player — Fase 7.A: Cola Dual (Automática + Manual)

## 📋 Resumen de la Fase
Refactor de mayor riesgo de la Fase 7 (H-3 de `plan_fase_7.md`): la cola de reproducción pasó de
una lista plana (`List<SyncoraTrack> queue` + `int currentIndex`) a un **modelo dual** —
`manualQueue` (FIFO, sobrevive a cambios de shuffle/playlist) + `autoQueue` (regenerable desde el
contexto activo) + `currentTrack`/`currentOrigin` como campos propios del estado + `history` (pila
única de reproducción para "anterior", D-3). Todo lo demás de la Fase 7 depende de este modelo.

---

## 🏗 Componentes Desarrollados

### 1. Modelo de datos (`syncora_player_controller.dart`, `player_models.dart`)
- `SyncoraPlayerState`: `currentTrack`, `currentOrigin` (`QueueOrigin.manual`/`.auto`),
  `manualQueue`, `autoQueue`, `originalContextTracks` (snapshot del contexto activo, usado para
  regenerar `autoQueue` al togglear shuffle o hacer loop con repeat-all), `history`
  (`List<HistoryEntry>`, tope 50).
- **Avance** (`_advance()`): prioridad `manualQueue` > `autoQueue` siempre (D-1); si ambas colas se
  agotan y `repeatMode == all`, regenera `autoQueue` desde `originalContextTracks` (mezclada si
  shuffle activo). Empuja el `currentTrack` anterior a `history` con su origen.
- **Retroceso** (`_retreat()`): saca la última entrada de `history`; el `currentTrack` que se deja
  atrás vuelve al frente de SU propia cola de origen — así "siguiente" tras un "anterior" reproduce
  la misma pista de la que se venía (D-3).
- `setQueue(tracks, {startIndex, autoplay, activeContextId})` mantiene su firma pública (11 call
  sites externos sin tocar). `manualQueue` nunca se toca al cambiar de contexto (D-1).
- `playFromQueue(QueueOrigin, int)` reemplaza a `playIndex`/`skipToQueueIndex`: descarta sin
  historial las pistas anteriores al índice saltado (nunca sonaron).
- `removeFromQueue`/`reorderQueue` ahora toman `QueueOrigin` — operan sobre una sola cola, nunca
  cruzan entre manual/auto (7.A.10).
- `_skipSilently()` (salto offline, Fase 6) es de solo-lectura mientras evalúa candidatos: recorre
  `manualQueue` completo antes que `autoQueue` y solo muta el estado al encontrar uno descargado —
  la manual nunca se drena por el simple hecho de estar offline.
- `PlayerSessionStorage`: esquema nuevo (`schemaVersion: 2`) con ambas colas + historial + pista
  actual. Una sesión del formato viejo o que no matchea el esquema se descarta por completo
  (7.A.6), nunca se intenta migrar.
- `os_controls/syncora_audio_handler.dart`: expone al SO una vista combinada de solo lectura
  `[currentTrack, ...manualQueue, ...autoQueue]`; `skipToQueueItem` traduce el índice combinado de
  vuelta a `playFromQueue`.

### 2. UI de cola (`lib/features/player/widgets/queue_view.dart`, nuevo)
Consolida tres implementaciones de cola que antes vivían duplicadas en `app_shell.dart` (sidebar de
escritorio), `mini_player.dart` y `player_fullscreen_screen.dart` (hojas móviles) en un único
widget compartido `QueueView`:
- Dos secciones visualmente diferenciadas ("A continuación" / "Siguiente de {contexto}") más un
  bloque "Reproduciendo ahora" para la pista actual.
- `CustomScrollView` + `SliverReorderableList` por sección (scroll y auto-scroll reales al
  arrastrar, a diferencia de un `ReorderableListView` anidado en un `SingleChildScrollView`).
- Deslizar a la izquierda para eliminar (`Dismissible`); deslizar a la derecha en listas normales
  para agregar a la cola (`TrackTile.onAddToQueue`, ya existía antes de esta fase).
- Modo "Editar" con selección múltiple (checkboxes, "Eliminar seleccionadas" / "Mover arriba"),
  indexado por `track.id` en vez de posición para no invalidarse si la cola avanza mientras el modo
  sigue abierto.
- Empty states: solo se muestra el de "cola vacía" cuando no hay `currentTrack` **y** ambas colas
  están vacías.
- Keys estables ante reorder (`origin_id_ocurrencia`, no por índice absoluto).

### 3. Simplificación de `playlist_detail_screen.dart`
`isPlayingTrack` pasó de comparar contra `queue.length`/`currentIndex` a `currentTrack?.id ==
track.id` — regresión aceptada y documentada para el caso raro de tracks duplicados dentro de la
misma playlist (el índice ya no tiene un equivalente estable en el modelo dual).

---

## 🔎 Revisión independiente y bugs corregidos

Dado que esta es la fase de mayor riesgo de regresión del plan, se corrió una revisión de código
independiente de esfuerzo `xhigh` (6 pases con Opus, ángulos distintos: escaneo línea por línea,
comportamiento eliminado, rastreo cruzado/wrappers, trampas de Dart/Flutter, calidad
reuse/simplificación/eficiencia/altitude, y convenciones de `CLAUDE.md`). Se encontraron y
corrigieron **15 bugs reales** antes de cerrar la fase, varios corroborados independientemente por
3-5 de los 6 revisores:

**Críticos (violaban invariantes cerrados o perdían datos):**
- Togglear shuffle podía vaciar `autoQueue` por completo (filtraba por `originalContextTracks` en
  vez de reordenar la cola actual — las recomendaciones de Autoplay desaparecían).
- `_skipSilently()` destruía `manualQueue` (violando D-1) y ensuciaba `history` con pistas que
  nunca sonaron — reescrito a solo-lectura mientras evalúa candidatos.
- `addToQueue`/`playNext` con nada sonando dejaban la pista agregada inalcanzable (sin
  `currentTrack`, sin mini-player visible).
- `clearQueue()` no limpiaba `originalContextTracks`, así que repeat-all resucitaba la cola recién
  limpiada.
- Una entrada de historial corrupta en la sesión guardada descartaba `currentTrack`/ambas
  colas/posición completos, no solo el historial.

**Importantes:**
- `setQueue()` ignoraba el shuffle ya activo al construir la `autoQueue` nueva.
- Off-by-one en `skipToQueueItem` (controles del SO) cuando no había pista actual.
- Guard de reentrada (`_isTransitioning`) era un no-op — se implementó un guard real, separando
  cada método público guardado de un núcleo interno sin guard usado por las cascadas internas de
  auto-skip (para no autobloquearse).
- Selección múltiple de `QueueView` usaba índices que quedaban obsoletos si la cola avanzaba con el
  modo Editar abierto.
- Sidebar de escritorio había perdido el resaltado/presencia de la pista actual en la lista.
- Cierre de la hoja de cola usaba un `context` potencialmente obsoleto tras un `await` largo de
  extracción.
- `ReorderableListView` anidado en un scroll no-scrollable impedía el auto-scroll al arrastrar en
  colas largas.

Detalle completo (archivo/línea/escenario de cada uno) en el historial de revisión de esta sesión.
Todos los P0 y P1 quedaron corregidos con test de regresión dedicado; dos ítems de calidad menor
(batch de mutaciones en acciones múltiples, wrap-around de "anterior" con repeat-all e historial
vacío) se dejaron pendientes deliberadamente por ser de alcance nuevo, no bugs puntuales — quedan
anotados para una fase de pulido futura si se vuelve a tocar esta área.

---

## 📑 Verificación de Pruebas Automatizadas

- `flutter analyze`: limpio (solo lints `info` preexistentes, ninguno nuevo).
- `flutter test`: **216 tests, 0 fallos** (1 skip preexistente no relacionado). El archivo del
  controlador creció a 45 tests, cubriendo: reordenamiento por sección, FIFO manual, `playNext` al
  frente, shuffle sin tocar la manual, `setQueue` sin tocar la manual, "anterior" volviendo a una
  pista manual, consumo eliminando de la cola de origen, prioridad manual incluso con auto en
  curso, regeneración por repeat-all, semántica de `removeFromQueue`/`clearQueue`/`playFromQueue`,
  salto offline sin loop infinito (con y sin repeat-all), restauración de sesión (incluida la
  descarte del formato viejo), y las regresiones específicas de los 15 bugs encontrados en revisión
  (incluyendo la cascada de auto-skip interna con el nuevo guard real).

## 🧪 Prueba manual pendiente (matriz de pruebas, se agrupa al final de la Fase 7)

- Arrastrar y soltar en la cola (`matriz_de_pruebas.md`, ítem explícito de Fase 7) — verificar en
  dispositivo real que el auto-scroll durante el drag funciona en ambas secciones con una cola
  larga, y que el modo Editar + selección múltiple se siente bien en móvil.
