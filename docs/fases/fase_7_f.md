# Syncora Player — Fase 7.F: Funciones de IA (sobre 7.E)

Documento único para las 4 funciones de IA de la Fase 7.F. Se completa por sub-bloque a medida que
cada uno cierra.

## 📋 7.F.1 — Crear playlist con IA

### Resumen

Primera función de IA con UI rica sobre la infraestructura de 7.E: formulario de texto libre +
parámetros opcionales → llamada a `create_playlist` → matching contra Deezer (reusando la cadena de
fallback de la importación CSV) → vista previa editable → guardar. Todo el flujo vive en un solo
`AppBottomSheet` (`lib/features/library/ai_playlist/ai_create_playlist_sheet.dart`) que cambia de
contenido según un `enum _Step { form, callingAi, matching, preview, saving }` interno, en vez de
encadenar varias hojas — más simple de navegar y evita perder el estado del formulario entre pasos.

### Componentes

- **`ai_create_playlist_sheet.dart`** (nuevo) — el flujo completo. Entrada primaria: texto libre.
  Panel de parámetros opcional/colapsado: presets de cantidad (25/50/100/200, tope duro 300),
  máximo por artista, género/mood, sliders familiaridad↔descubrimiento y nicho↔popular, y selector
  "basado en una playlist mía" (D-11, restringido a playlists propias vía `watchAllPlaylists()`
  local). Nombre y descripción se piden en la misma llamada que las canciones (D-5 aplica los topes
  numéricos del lado del cliente, con ~30% de margen). Vista previa con +/- local por canción
  (gratis) y "afinar con IA" (sí gasta una petición, reenvía el borrador actual como `contextTracks`
  con `params.isRefinement: true`).
- **`playlist_import_export_service.dart`** — nuevo método compartido
  `createPlaylistWithMatchedTracks(...)` (D-8), extraído literal del flujo de importación CSV para
  que ambos caminos usen exactamente el mismo código de inserción canónica (local → remoto sin
  `remoteId` → pistas → lote remoto → recién ahí `remoteId`, evita la condición de carrera ya
  documentada en el propio método).
- **`library_screen.dart`** — el import CSV ahora llama al método compartido en vez de tener su
  propia copia inline; comportamiento verificado idéntico (ver revisión abajo).
- **`ai_assistant_service.dart`** — `createPlaylist` ganó `contextTracks` opcional, con doble uso
  distinguido por `params['isRefinement']` (playlist de referencia D-11 vs. borrador a afinar).
- **`prompts.ts`** — el prompt de `create_playlist` se amplió para interpretar `params`
  (genre/mood/familiarity/popularity, dos ejes independientes) y ambos significados de
  `contextTracks`. Extensión natural de 7.E, no reabre sus decisiones.

### Revisión independiente y bugs corregidos

Revisión hecha por un subagente Sonnet separado del que implementó, sobre el diff completo sin
commitear. Además, durante la verificación previa del gate de tests (`flutter test`), el
orquestador encontró y corrigió directamente 3 bugs reales antes incluso de pedir la revisión:

1. **Churn de suscripciones Drift** (`_buildReferencePlaylistPicker`): `stream:
   ref.read(playlistDaoProvider).watchAllPlaylists()` se creaba inline en cada rebuild del
   `StreamBuilder` — cada `setState` del panel de parámetros generaba un `Stream` nuevo, forzando a
   Flutter a cancelar y resuscribir la suscripción Drift en cada frame. Arreglado hosteando el
   stream a un campo `late final` del `State`, creado una sola vez.
2. **Timer de Drift pendiente en tests** (`ai_create_playlist_sheet_test.dart`): Drift difiere la
   limpieza de sus streams un turno de event loop vía un `Timer` interno (comentario explícito del
   propio código de Drift al respecto), y ese timer seguía pendiente cuando `flutter_test` verifica
   invariantes al cerrar el test — `tearDown` no llega a tiempo de evitarlo. Arreglado con el flag
   oficial de Drift pensado exactamente para esto: `DatabaseConnection(..., closeStreamsSynchronously:
   true)` en el `setUp` del test.
3. **`FlutterSecureStorage` real colgando un test**: el test no mockeaba `aiKeyStorageProvider`, así
   que `AiAssistantService.invoke()` llamaba al `FlutterSecureStorage` real (canal de plataforma sin
   binding en `flutter_test`) ANTES de siquiera llegar a `Supabase.instance` — el canal no lanza ni
   resuelve, dejando el paso "generando" sin salida y a `pumpAndSettle` sin poder asentarse jamás.
   Arreglado inyectando un `_FakeAiKeyStorage` vía `ProviderScope.overrides`.

La revisión del subagente, sobre el diff ya con esos 3 arreglos aplicados, no encontró ningún P0.
Encontrados y corregidos los siguientes P1/P2:

4. **(P1) Cobertura de test insuficiente en el camino exitoso** — el test original solo cubría el
   camino de error ("IA inalcanzable"), dejando sin probar ~660 de 863 líneas del archivo (matching
   → vista previa → toggle → guardar). Corregido agregando un test de camino feliz completo, con
   dobles de `aiAssistantServiceProvider` (invoker fake) y `deezerApiProvider` (`_FakeDeezerApi`,
   subclase que sobreescribe `search()` sin tocar red real) — cubre generar → matching → vista
   previa con la pista → excluir/incluir → guardar → cierre de la hoja. (Un tercer bug de timer
   pendiente apareció al escribir este test: `AppToast` deja un `Timer` real de auto-dismiss a 3s;
   mismo patrón de fix que el bug #2, dándole a `pumpAndSettle` un `duration` por pump mayor a 3s.)
5. **(P2) Doble-tap en "Crear con IA"** — entre tocar el botón y que `_generate` recién marque
   `_step = callingAi`, `_loadReferenceTracks` (D-11) hace un `await` a la DB local con el botón
   todavía habilitado; un doble-tap podía disparar dos `_generate` concurrentes que se pisaban.
   Corregido con un flag `_isSubmitting` que deshabilita el botón durante toda la ventana.
6. **(P2) Mensaje de validación optimista** — el guard de envío solo exigía que el panel de
   parámetros estuviera *expandido*, no que tuviera algo elegido (los sliders arrancan en 0.5
   neutral); el mensaje de error prometía "elige alguno" mientras dejaba pasar un submit sin nada
   realmente elegido. Corregido con `_hasAnyParamSet`, que exige al menos un valor no-default.
7. **(P2) Carácter soft-hyphen invisible en `prompts.ts`** — typo cosmético en la palabra
   "underground" del prompt de `popularity`, corregido.

**No corregido, documentado como límite conocido de baja severidad:** si la IA sugiere dos pistas
que la cadena de matching resuelve al mismo `DeezerTrack.id` (mismo id de Deezer), la vista previa
muestra dos filas pero `_excludedTrackIds` (un `Set<int>` por id) las trata como una sola al
alternar +/-. Solo alcanzable con sugerencias/matching duplicados de la propia IA; no vale la pena
cambiar la identidad de la estructura de datos para un caso tan marginal en esta primera versión.

**Sin regresiones en `library_screen.dart`:** el refactor del import CSV preserva el orden canónico
documentado (local → remoto sin `remoteId` → pistas → lote remoto → `remoteId`) y el mismo
comportamiento "local-only silencioso" si falla la subida remota. El único cambio de comportamiento
es que la creación de playlist local+remota ahora ocurre *después* de que termina el stream de
matching en vez de en paralelo con su inicio — sin efecto visible, ya que `playlistId`/
`remotePlaylistId` no se usaban en ningún otro lado del diálogo de importación.

### Verificación de pruebas

- `flutter analyze`: limpio (28 lints `info` preexistentes, sin relación con este cambio).
- `flutter test`: **296 tests, 0 fallos** (suite completa), incluidos 5 tests nuevos de
  `ai_create_playlist_sheet_test.dart` y 3 de `create_playlist_with_matched_tracks_test.dart`.

### Pendiente

Ninguno bloqueante. 7.F.2 (crear cola con IA) y 7.F.3 (modificar playlist con IA) pueden reusar el
widget de vista previa de sugerencias, el matching contra Deezer, y el patrón de inserción canónica
construidos aquí — revisar si conviene extraer algo compartido antes de duplicar al implementarlos.

---

## 📋 7.F.2 — Crear cola con IA

### Resumen

Segunda función de IA, sobre la infraestructura de 7.E y reusando piezas de 7.F.1. Formulario
(prompt libre, toggle cola-nueva/basada-en-cola-actual, toggle intercalar/cola-manual, dropdown de
cantidad 10/25/50/100 default 25) → generación → matching contra Deezer → vista previa → aplicar.
El atajo "✨ Mejorar esta cola" (D-9) prellena basada-en-cola-actual + intercalar + 25 y dispara
directo sin mostrar el formulario.

### Componentes

- **`ai_create_queue_sheet.dart`** (nuevo, `lib/features/player/ai_queue/`) — el flujo completo,
  mismo patrón de un solo `AppBottomSheet` con pasos internos que 7.F.1.
- **`ai_generation_steps.dart`** (nuevo, `lib/core/widgets/`) — los widgets de progreso/vista previa
  de 7.F.1 (`AiGeneratingIndicator`, `AiMatchingProgress`, `AiMatchedTrackList`,
  `AiUnmatchedSuggestionsSection`) extraídos a un archivo compartido; 7.F.1 se refactorizó para
  usarlos también, con su comportamiento/apariencia verificados idénticos en la revisión (ver
  abajo). `_clampInt`, el enum `_Step`, `_kHardCountCap` y el estilo de `ChoiceChip` siguen
  duplicados entre las dos hojas y el esqueleto `_generate` → matching (~80 líneas) también —
  **7.F.3 lo va a necesitar por tercera vez; extraerlo antes de esa fase, no después.**
- **`syncora_player_controller.dart`** — dos métodos nuevos: `addAllToQueue(List<SyncoraTrack>)`
  (agregado en lote al final de la manual, FIFO D-2) e `interleaveIntoAutoQueue(List<SyncoraTrack>)`
  (D-9, ver algoritmo abajo). También ganó un `sessionStorage` inyectable opcional en el
  constructor (default `PlayerSessionStorage()` real, igual que antes) — solo para poder testear
  con un doble el único camino real hacia `currentTrack == null` con `manualQueue` no vacía (una
  sesión restaurada), que motivó el fix de D-1 de abajo.
- **`queue_view.dart`** — botón "Crear cola con IA" + atajo "Mejorar esta cola" en la toolbar, y un
  botón de entrada en el estado vacío (`EmptyStateWidget` ya tenía slot `action`): sin él, la
  entrada de IA quedaba inalcanzable justo en el caso de uso principal ("cola nueva" con la cola
  totalmente vacía). Mismo patrón D-14 (ícono `stars-broken`, bold mientras genera) y gating de
  conexión que los otros 3 puntos de entrada.

### Revisión independiente y bugs corregidos

Revisado por un subagente **Opus** (no Sonnet como el resto de 7.F): los cambios de
`syncora_player_controller.dart` tocan el mismo invariante D-1 (cola manual vs. automática) que
justificó Opus para la revisión de 7.A, mismo criterio de riesgo. No encontró ningún P0. P1/P2
encontrados y corregidos:

1. **(P1) `interleaveIntoAutoQueue` podía violar D-1 en un borde real** — el método documentaba
   "nunca toca `manualQueue`", pero su `_advance()` de conveniencia (arrancar reproducción si no
   había nada sonando) no distinguía "no hay nada sonando porque todo está vacío" de "no hay nada
   sonando pero la cola manual del usuario tiene pistas esperando" (el estado documentado en el
   propio código como alcanzable tras `_restoreSession` — una sesión restaurada con `currentTrack`
   null y `manualQueue` no vacía). En ese borde, "Mejorar esta cola" promovía una pista de "A
   continuación" del usuario a "sonando ahora" sin que lo pidiera. Corregido: el auto-arranque de
   conveniencia ahora exige `manualQueue` también vacía, no solo `currentTrack == null`.
   Regresión cubierta con un test dedicado que reproduce el estado real (vía el `sessionStorage`
   inyectable mencionado arriba + un doble de `PlayerSessionStorage` que devuelve esa sesión).
2. **(P1) Paso de intercalado fijo dejaba las sugerencias sobrantes en un bloque al final** — ver
   **H-8** en `docs/plan_fase_7.md`. Corregido con paso adaptativo
   (`autoQueue.length ~/ tracks.length`, mínimo 1):
   ```
   autoQueue=[a1,a2,a3,a4,a5] (5), sugerencias=[ai1,ai2] (2) -> paso = 5~/2 = 2
   resultado: [a1, a2, ai1, a3, a4, ai2, a5]   (antes, paso fijo 3: [a1,a2,a3,ai1,a4,a5,ai2])
   ```
   Con pocas sugerencias contra una `autoQueue` abundante, el paso resultante es más disperso que
   un "cada 3" fijo (correcto: no hay razón para amontonar todas las sugerencias al principio). Con
   una `autoQueue` muy corta frente a muchas sugerencias, sigue quedando un bloque residual al
   final — inevitable, no hay estructuralmente huecos suficientes para repartir todo.
3. **(P2) `ref.read(deezerApiProvider)` antes del chequeo de `mounted`** en `_matchAndSettle` —
   copiado literal de la misma forma en 7.F.1. Si el usuario cierra la hoja mientras la IA está
   respondiendo (`await service.createQueue/createPlaylist(...)`), `ref` ya no es seguro de usar al
   volver. Corregido en **ambos** archivos (7.F.2 y 7.F.1, aunque 7.F.1 ya estaba cerrada — es el
   mismo bug real, no una reapertura de sus decisiones).
4. **(P2) `addPostFrameCallback` sin guarda de `mounted`** en el modo `autoImprove` — corregido.
5. **(P2) `_buildQueueContext` podía descartar la pista actual al muestrear** por encima del tope de
   seguridad (>3000 pistas): el muestreo por frecuencia de artista no preservaba `currentTrack`, la
   pista más relevante para "continuá desde acá". Corregido preservándola siempre, fuera del
   muestreo.

**No corregido, documentado como límite conocido:** `_Step.applying` es un paso que nunca llega a
renderizarse (`_apply()` no tiene ningún `await`, así que el spinner asociado es inalcanzable) —
cosmético, no afecta el comportamiento, se deja para una limpieza futura junto con la extracción
compartida del punto de "duplicación" arriba. Tampoco hay deduplicación de sugerencias de la IA
contra la cola existente (mismo hueco que 7.F.1); no crashea, solo puede mostrar una pista
repetida.

**Refactor de `ai_create_playlist_sheet.dart` (fase 7.F.1, ya cerrada):** confirmado fiel línea por
línea contra el original — mismo padding, alturas, íconos (`bold` vs `broken` por D-14), colores, y
el `_showUnmatched` que pasó al `State` del widget extraído mantiene la misma vida útil práctica.
Sus 5 tests existentes pasan sin modificarlos.

### Verificación de pruebas

- `flutter analyze`: limpio (28 lints `info` preexistentes, sin relación con este cambio).
- `flutter test`: **309 tests, 0 fallos** (suite completa) — 12 tests nuevos del implementador (5
  de `ai_create_queue_sheet_test.dart`, 7 de controller) más 1 test reescrito y 1 agregado durante
  la corrección de los P1 de la revisión.

### Pendiente

Ninguno bloqueante. Antes de implementar 7.F.3, evaluar extraer el esqueleto `_generate` → matching
compartido entre 7.F.1 y 7.F.2 (ver punto de "duplicación" en Componentes) para no triplicarlo.
