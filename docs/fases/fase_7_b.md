# Syncora Player — Fase 7.B: Radio / Cola Infinita (sin IA)

## 📋 Resumen de la Fase
Extiende automáticamente la cola automática (`autoQueue`, modelo dual de la Fase 7.A) cuando baja
a ≤5 pistas, generando un lote de 25 canciones sobre `/artist/{id}/radio` y `/artist/{id}/related`
de Deezer. Activada por defecto (D-10), no consume presupuesto de Gemini/IA.

---

## 🏗 Componentes Desarrollados

### 1. `DeezerApi` (`lib/data/apis/deezer_api.dart`)
- `getArtistRadio(int artistId)` y `getArtistRelated(int artistId)`, siguiendo el patrón exacto del
  resto del archivo (rate limiter, filtro duración/podcast, caché LRU propia por endpoint).
  `getArtistRelated` devuelve `List<DeezerArtist>` (confirmado contra la API real: el endpoint
  expone artistas relacionados, no tracks).
- Se agregaron `connectTimeout`/`receiveTimeout` al `Dio` compartido de `DeezerApi` (robustez
  general de toda la API, no solo de radio — un socket colgado ya no deja peticiones sin resolver
  nunca).

### 2. `RadioService` (`lib/features/player/radio/radio_service.dart`, nuevo)
Sigue el precedente de `SearchRanking`: la mayor parte de la lógica es un conjunto de funciones
**puras**, testeadas contra fixtures JSON sin mockear Dio (no hay precedente de eso en el
proyecto):
- `countArtistFrequency` — frecuencia de artistas en `originalContextTracks`.
- `weightedSampleArtists` — muestreo aleatorio ponderado sin reemplazo, determinista con un
  `Random` inyectado.
- `completeSeeds` — completa semillas con artistas relacionados cuando hay menos de 5 distintos en
  el contexto (cubre los casos de 1 y 2-4 artistas).
- `interleaveRoundRobin` — combina las listas de radio por artista intercalando una pista de cada
  semilla por turno (no en bloques), para que las 5 semillas contribuyan proporcionalmente al lote
  final en vez de que la primera domine.
- `filterDedupQuota` — filtra por `SearchRanking.isPopularTrack` (reusa el umbral existente,
  `rank` ~300k), deduplica, recorta a la cuota de 25.
- `generateBatch` — orquestador con I/O real: cuenta frecuencia → muestrea semillas → completa si
  faltan → pide radios en paralelo (`Future.wait`) → pipeline puro → reintento con buffer si no
  alcanza 25 → fallback a `getTopCharts()` si el contexto está vacío o no queda nada.

### 3. Integración con el reproductor (`syncora_player_controller.dart`)
- Disparo centralizado al final de `playCurrent()` (cubre todos los caminos de retorno vía
  `finally`), sin bloquear la reproducción (`unawaited`).
- `excludeIds` para el pipeline: `manualQueue` + `autoQueue` + `originalContextTracks` +
  `currentTrack` + `history` (evita reofrecer pistas ya escuchadas).
- Guard `_isFetchingRadio` contra fetches concurrentes, con salida temprana si no hay conexión
  (`_isConnectedGetter`).
- `_tryAutoplay()` (mecanismo previo de Autoplay al agotarse ambas colas) ahora también respeta el
  toggle de Configuración — desactivarlo detiene *todo* el auto-relleno, no solo el disparo
  proactivo de radio.

### 4. Configuración
- `radioEnabledProvider` (`player_providers.dart`, `StateProvider<bool>`, default `true`) + switch
  nuevo en `settings_screen.dart` ("Radio / cola infinita"), mismo patrón que "Descargar solo con
  Wi-Fi" (no persiste entre reinicios — consistente con cómo ya funciona ese otro toggle; el
  proyecto no tiene `shared_preferences` todavía, llegará en la Fase 7.I).

---

## 🔎 Revisión y bugs corregidos

Revisión de código independiente (Opus) encontró y se corrigieron 5 problemas antes de cerrar la
fase:

1. **La guarda contra condición de carrera era inerte en el caso común.** Comparaba
   `activeContextId`, pero la mayoría de los `setQueue()` de la app no pasan ninguno (`null`), así
   que `null != null` nunca detectaba un cambio de contexto real. Se reemplazó por un contador
   monotónico dedicado `_contextGeneration` (mismo espíritu que `_playGeneration`, pero a nivel de
   "sesión de contexto" en vez de "pista individual" — no se incrementa al avanzar dentro de la
   misma playlist, solo al llamar `setQueue()`).
2. **La radio podía reofrecer canciones ya escuchadas** — faltaba `history` en `excludeIds`.
3. **El toggle no apagaba `_tryAutoplay()`** — ver punto 3 de arriba.
4. **Una sola semilla podía dominar el lote de 25** — el pool se armaba concatenado por bloques de
   artista en vez de intercalado; se agregó `interleaveRoundRobin`.
5. **`_isFetchingRadio` podía quedar trabado para siempre** — sin timeouts en el `Dio` de
   `DeezerApi`, un socket colgado dejaba el guard en `true` el resto de la sesión.

Todos con test de regresión dedicado. Detalle completo en el historial de revisión de esta sesión.

---

## 📑 Verificación de Pruebas Automatizadas

- `flutter analyze`: limpio (solo lints `info` preexistentes).
- `flutter test`: **248 tests, 0 fallos** (1 skip preexistente no relacionado). Incluye:
  muestreo ponderado (estadístico, semillas fijas, no flaky), deduplicación, filtro de rank,
  completado de semillas con <5 artistas, caso de 1 artista, round-robin de interleaving, disparo
  correcto al llegar a ≤5 en `autoQueue`, no-disparo con el toggle apagado, guard de fetch
  concurrente, descarte de lote con contexto nulo→nulo distinto, aceptación de lote con mismo
  contexto, historial excluido, y `_tryAutoplay` respetando el toggle.
- `RadioService.generateBatch` (el orquestador con I/O) no tiene test unitario directo — mismo
  nivel de cobertura que `DeezerApi` en el resto del proyecto (sin precedente de mockear Dio).

No hay pruebas manuales nuevas específicas de esta fase para `matriz_de_pruebas.md` — el
comportamiento es interno/automático; se valida indirectamente al probar la cola en general.
