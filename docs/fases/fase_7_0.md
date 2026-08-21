# Syncora Player — Fase 7.0: Prerequisito — Registro de Historial de Escucha

## 📋 Resumen de la Fase
Primer bloque de la Fase 7 (Experiencia Premium e IA). `ListeningHistoryDao.recordEntry()` existía
desde fases anteriores pero **nunca tenía un llamador real** (hallazgo H-1 de `plan_fase_7.md`): el
historial de escucha estaba completamente vacío, lo que dejaba sin datos tanto a la personalización
de Inicio como a la futura pantalla de Estadísticas (7.G). Esta fase activa el registro real y
corrige un bug de duplicación en la sincronización (H-2) que habría inflado el historial en cuanto
se activara el registro. Es un prerequisito bloqueante: va primero para que el historial empiece a
acumularse mientras se construyen el resto de las fases.

---

## 🏗 Componentes Desarrollados

### 1. Deduplicación de sincronización (7.0.1)
- Columna `syncedAt` (nullable) en la tabla Drift `ListeningHistory` (`schemaVersion` 4→5).
- `ListeningHistoryDao.getUnsyncedHistory()` / `markSynced(id)`.
- `SyncService._syncListeningHistoryInternal()` ahora sube solo entradas pendientes y las marca
  **una por una**, únicamente tras un `upsert` remoto exitoso; si una falla, se detiene el lote sin
  marcar (se reintenta en el siguiente sync).
- Red de seguridad del lado del servidor: `SupabaseHistoryRepository.insertListeningHistory()` pasó
  de `.insert()` a `.upsert(..., onConflict: 'user_id,track_id,listened_at')`, usando el
  `listened_at` fijo ya guardado localmente (no un timestamp nuevo por intento). Migración nueva:
  `supabase/migrations/20250001000007_listening_history_dedup.sql` (índice único
  `user_id, track_id, listened_at`).
  ⚠️ **Pendiente del desarrollador:** esta migración todavía no está aplicada en el proyecto real de
  Supabase — hay que correr `supabase db push` antes de que el `upsert` funcione en producción. Hasta
  entonces, el `upsert` fallará silenciosamente (capturado por el `try/catch` del sync) y el
  historial se quedará acumulado localmente sin subir, sin romper nada ni perder datos.

### 2. Registro de escucha real (7.0.2, `SyncoraPlayerController`)
- Se mide **tiempo de audio realmente reproducido**, no wall-clock ni `posición final − inicial`:
  se suman únicamente avances "naturales" de `engine.position` entre ticks consecutivos del motor
  mientras reproduce (`delta > 0` y `≤ 3s`); un seek (adelante o atrás) produce un salto mayor que se
  ignora.
- Umbral D-16: se dispara `recordEntry()` al alcanzar `min(50% de la duración, 30s)`.
- `_beginListenTracking()` se invoca antes de cada intento de reproducción y **siempre** reinicia el
  acumulado — cualquier llamada representa un intento de escucha nuevo (pista distinta, reinicio
  explícito, o una vuelta nueva en loop), nunca la continuación de uno anterior.
- Enganchado en `playCurrent()`, `_onEngineState`, `_onComplete()` y `dispose()` (red de seguridad
  para pistas cortas o motores que no emiten un último tick de posición antes de completar — lee
  `_engine.position` en vivo, no el último estado ya procesado).

### 3. Género (7.0.3)
- Se investigó de dónde sale `genre` en el flujo real de reproducción: ni `/search` ni
  `/artist/{id}/top` de Deezer lo traen en `DeezerTrack`; solo `/album/{id}` lo tiene, y llamarlo por
  cada escucha sería una petición extra cara y sin caché por canción reproducida. Decisión: se
  propaga tal cual venga ya en la pista (hoy, en la práctica, casi siempre `NULL`) en vez de forzar
  esa llamada — deja el camino abierto para cuando exista una fuente barata, sin bloquear el resto de
  la fase. **Sin género no hay "top géneros" en Estadísticas (7.G)** — pendiente de resolver cuando
  se llegue a esa fase.

### 4. Personalización de Inicio (7.0.4)
- `personalizedSectionsProvider` (`home_providers.dart`) ya dependía solo de
  `historyDao.getTopArtistIds()` estar vacío o no — no necesitó cambios de código. Se agregó un test
  a nivel de DAO que prueba que `getTopArtistIds()` refleja historial real una vez hay escuchas
  registradas, que es la condición exacta que saca a Inicio de su fallback hardcodeado
  (Coldplay/Bad Bunny/Dua Lipa).

---

## 🔎 Hallazgos de la revisión independiente (corregidos en la misma fase)

Una revisión de código de esfuerzo alto sobre el diff encontró y se corrigieron 4 bugs de
correctitud en la lógica de acumulación de 7.0.2, todos relacionados con caminos que reinician o
repiten la pista actual sin pasar por el reseteo del acumulado:

1. **Repeat-one nunca volvía a registrar tras la primera vuelta** — `_onComplete()` reinicia la
   pista con `seek(0)+play()` sin pasar por `playCurrent()`. Fix: llamar a
   `_beginListenTracking()` explícitamente en esa rama.
2. **"Anterior" (reinicio de la pista actual, >3s) no reseteaba el acumulado** — fusionaba dos
   intentos de escucha en uno. Mismo fix.
3. **`_beginListenTracking()` preservaba progreso entre pasadas genuinamente separadas** de la misma
   pista (ej. cola de 1 pista en repeat-all) — se simplificó a un reseteo incondicional en cada
   llamada, ya que ningún caso real necesitaba preservar progreso (un reintento de extracción tras
   error siempre parte de acumulado cero).
4. **La "red de seguridad" de `_onComplete`/`dispose` era un no-op** — reutilizaba el mismo estado ya
   procesado por el último tick en vez de leer la posición en vivo del motor. Fix: leer
   `_engine.position` directamente.

Los 4 quedaron cubiertos con tests de regresión nuevos. Detalle completo en el historial de la
revisión de esta sesión (no se abrió un nuevo hallazgo `H-N` en `plan_fase_7.md` porque no cambia
ninguna decisión de diseño cerrada — es una corrección de implementación dentro del alcance ya
definido por 7.0.2).

---

## 📑 Verificación de Pruebas Automatizadas

- `flutter analyze`: limpio (solo lints `info` preexistentes de `prefer_initializing_formals`, mismo
  patrón ya usado sin ignorar en el resto del archivo).
- `flutter test`: **192 tests, 0 fallos** (1 skip preexistente no relacionado). Incluye:
  - Umbral D-16 (justo por debajo/por encima, regla del 50% en pistas cortas).
  - No inflar por seek adelante; no doble conteo por seek atrás dentro de la misma pista.
  - Cambiar de pista antes del umbral no registra esa instancia.
  - Completar naturalmente dispara el registro; pausar/reanudar preserva el progreso sin contar
    tiempo pausado.
  - Los 4 tests de regresión de la revisión (repeat-one, reinicio con "anterior", cola de 1 pista en
    repeat-all, red de seguridad con posición en vivo).
  - Deduplicación de sync: solo sube pendientes y marca tras éxito; no reenvía ya sincronizadas; no
    marca si falla la subida.
  - DAO: filas nuevas sin sincronizar por defecto, `getUnsyncedHistory` excluye sincronizadas,
    `markSynced` deja timestamp, `getTopArtistIds` refleja historial real.

No hay pruebas manuales nuevas de `matriz_de_pruebas.md` específicas de esta fase — el registro de
historial es invisible para el usuario final hasta que se construya la pantalla de Estadísticas
(7.G), donde sí se agruparán las pruebas manuales correspondientes al final de toda la Fase 7, según
la metodología acordada.

---

## ⚠️ Pendiente operativo para el desarrollador

Aplicar la migración `20250001000007_listening_history_dedup.sql` con `supabase db push` cuando
tenga oportunidad — no bloquea el resto de la Fase 7, pero hasta que se aplique, el historial de
escucha no llegará a sincronizarse con Supabase (se queda acumulado localmente en Drift, sin
pérdida de datos ni errores visibles para el usuario).
