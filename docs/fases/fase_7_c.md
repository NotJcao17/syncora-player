# Syncora Player — Fase 7.C: Auto-Skip Inteligente Completo

## 📋 Resumen de la Fase
Cubre el **Auto-Skip lógico**: cuando una pista no se resuelve en el catálogo estando online
(`ExtractionError.notFound`/`unknownError`), el reproductor ya saltaba automáticamente a la
siguiente — 7.C le agrega feedback visual al usuario (toast + marcado gris) y un guard de cascada
para no vaciar una playlist entera en silencio cuando hay muchos matches rotos seguidos. No toca la
política de 403/red (Fase 1) ni el salto silencioso offline (`_skipSilently`, Fase 6/7.A).

---

## 🏗 Componentes Desarrollados

### 1. Toast de auto-skip lógico (7.C.1)
Texto `"{título} no disponible — saltada"`, disparado **solo** cuando `_handleExtractionError`
toma la rama `notFound`/`unknownError`. Mecanismo: `PlayerNotice` (`player_models.dart`, con `id`
monotónico + `kind` + mensaje) expuesto en `SyncoraPlayerState.notice`, consumido en
`app_shell.dart` vía `ref.listen` comparando `previous?.notice?.id` vs `next.notice?.id` para
detectar "evento nuevo" sin repetirlo en cada rebuild.

### 2. Marcado en gris (7.C.2, D-21)
`SyncoraPlayerState.unavailableTrackIds` (`Set<String>`, solo en memoria — se resetea al reiniciar
la app, D-21 cumplido gratis). `TrackTile` reusa su patrón visual ya existente (opacidad 0.4,
colores atenuados) como tercera condición: una descarga local siempre gana sobre la marca de
sesión (`isPlayable = isDownloadedLocal || (isConnected && !isMarkedUnavailableThisSession)`) — si
el usuario descarga después una pista que había fallado en catálogo, vuelve a ser reproducible sin
quedar bloqueada en la UI.

### 3. Guard de cascada (7.C.3)
`_consecutiveLogicalFailures` se incrementa en cada fallo lógico; al llegar a 3 seguidos, detiene
el auto-skip (no vuelve a llamar a sí mismo), pausa el motor, y muestra un toast con acción
"Reintentar" (`resumeAfterCascadeGuard()`). El contador se resetea en **todo** punto de éxito real
de reproducción (extracción exitosa Y reproducción de descarga local, vía un helper compartido
`_onPlaybackStartedSuccessfully()`) y en todos los entry points manuales del usuario (`skipToNext`,
`skipToPrevious`, `playFromQueue`, `setQueue`) — el reset siempre ocurre *después* de pasar el
guard de reentrada `_isTransitioning`, nunca antes, para que taps repetidos en "Reintentar" no
pospongan indefinidamente una cascada ya en curso.

### 4. Hallazgo H-6 (bonus, documentado en el plan): aviso del guard 403/red
Se verificó que `lastError`/`lastErrorMessage` (diseñado en Fase 1 para el aviso visual de la pausa
por error persistente) nunca tenía consumidor en la UI. Se cableó con el mismo mecanismo de
`PlayerNotice` (`kind: persistentError`), con mensaje propio que nunca dice "saltada" (ahí no hay
skip, solo pausa).

### 5. Integración con la cola dual (7.C.4)
No requirió cambios: `skipToNext()` → `_advanceAndPlay()` → `_advance()` (Fase 7.A) ya respeta la
prioridad manual-antes-que-auto y elimina la pista fallida de su cola de origen. Verificado con
test dedicado, no reimplementado.

---

## 🔎 Revisión y bugs corregidos

Revisión de código independiente (Opus) encontró y se corrigieron 6 problemas antes de cerrar la
fase, tres de ellos verificados por mutación (reintroducir el bug y confirmar que el test
correspondiente falla):

1. El contador de cascada no se reseteaba al reproducir una descarga local con éxito (solo cubría
   el camino de extracción exitosa) — factorizado en un helper compartido.
2. `resumeAfterCascadeGuard()` reseteaba el contador **antes** del guard de reentrada — taps
   repetidos en "Reintentar" podían posponer la cascada indefinidamente.
3. `skipToPrevious()` era el único entry point manual que no reseteaba el contador.
4. Una pista marcada "no disponible" que luego se descargaba quedaba inutilizable en la UI pese a
   ser reproducible.
5. El test "el contador se resetea entre fallos" era un falso positivo — usaba `skipToNext()`
   manual en medio de la secuencia, que ya resetea el contador por sí mismo, enmascarando si el
   reset real (por éxito de reproducción) funcionaba. Reescrito para que la cadena
   fallo→éxito→fallo→fallo→fallo ocurra sin ningún entry point manual de por medio.
6. Aserciones de "el motor quedó pausado" que pasaban trivialmente por el valor inicial de
   `playing`, sin verificar que `pause()` se hubiera llamado realmente.

---

## 📑 Verificación de Pruebas Automatizadas

- `flutter analyze`: limpio (solo lints `info` preexistentes).
- `flutter test`: **259 tests, 0 fallos** (1 skip preexistente no relacionado). Incluye: 1 fallo
  aislado dispara toast+marca gris; 3 seguidos activan el guard y pausan el motor (con contador de
  `pause()` real, no solo el estado final); el contador se resetea en éxito de extracción y de
  descarga local sin pasar por un entry point manual; fallo en pista manual no descoloca la
  automática; `_skipSilently`/skip manual/error del motor no disparan nada de este mecanismo; el
  aviso H-6 no dice "saltada".

Sin pruebas manuales nuevas específicas para `matriz_de_pruebas.md` — el comportamiento se valida
completo con la suite automatizada.
