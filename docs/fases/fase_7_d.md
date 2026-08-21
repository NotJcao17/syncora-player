# Syncora Player — Fase 7.D: Crossfade en ambas plataformas

## 📋 Resumen de la Fase
Transición con crossfade entre pistas, restringida exclusivamente a pistas **descargadas/cacheadas
localmente** (Pitfall #17 — nunca en streaming, ni desde ni hacia). Se implementó como un wrapper
genérico y agnóstico de plataforma (`CrossfadeAudioEngine`) que envuelve dos instancias completas
de `AudioEngine` (sean `MediaKitEngine` en Windows o `JustAudioEngine` en Android — el wrapper no
necesita saberlo), en vez de construir dos implementaciones nativas de crossfade separadas por
plataforma. No se tocó la lógica interna de `MediaKitEngine`/`JustAudioEngine` (skip silence,
distinción EOF real vs. fallo de carga), solo se les agregó el método nuevo del contrato con un
fallback sin fade real.

> ⚠️ **Revisión de código post-implementación (dos rondas independientes) encontró un problema de
> diseño crítico y varios bugs de implementación, todos corregidos en esta misma fase** — ver
> sección "Rediseño" más abajo. La primera versión solo podía disparar un crossfade si el usuario
> tocaba "siguiente" a mano mientras la pista sonaba; el caso de uso principal (dejar sonar un
> álbum/playlist completo) no activaba nada. Quedó resuelto con un disparador **preventivo** que
> monitorea la posición y arranca la transición antes del final natural de la pista.

---

## 🏗 Componentes desarrollados

### 1. Contrato `AudioEngine` (7.D.3)
Método nuevo `Future<void> crossfadeToLocalSource(String path, Duration duration)` en
`audio_engine_state.dart`. `MediaKitEngine`/`JustAudioEngine` implementan un fallback simple
(`stop()` + `setLocalSource()` + `play()`, sin fade real, documentado como tal) — nunca se invocan
así en producción porque el wrapper de abajo es quien envuelve el motor real.

### 2. `CrossfadeAudioEngine` (7.D.1 y 7.D.2 — una sola implementación cubre ambas plataformas)
`lib/features/player/audio_engine/crossfade_audio_engine.dart`. `_active` (el motor que suena
ahora) se crea de inmediato; `_standby` (el motor de la próxima transición) se crea perezosamente
la primera vez que se necesita un crossfade real, para no gastar una segunda instancia nativa de
audio en usuarios que nunca lo activan. Los métodos normales del contrato delegan directo a
`_active` — cualquier transición sin crossfade es idéntica a la de siempre.

### 3. Cableado en la fábrica (`audio_engine_factory.dart`)
`createAudioEngine()` ahora envuelve **siempre** el motor real en `CrossfadeAudioEngine` (el
wrapper es barato sin crossfade activo). Se le agregó el parámetro `fadeDurationGetter` (default
`() => Duration.zero`, para no romper call sites/tests existentes), conectado desde
`player_providers.dart` hasta el nuevo setting de Configuración.

### 4. Configuración (7.D.5)
`crossfadeDurationProvider` en `player_providers.dart` (`StateProvider<Duration>`, default
`Duration.zero` = "off", mismo patrón no-persistido que `radioEnabledProvider`/
`downloadWifiOnlyProvider`). En `settings_screen.dart`, selector nuevo de píldoras (off/2s/4s/6s) —
no había un patrón de selector múltiple ya existente en la pantalla (solo `_buildSwitchTile`
on/off), así que se agregó `_buildCrossfadeSelector` siguiendo el estilo visual del resto
(`AppTheme`, tipografía, píldoras redondeadas).

---

## 🔁 Rediseño post-revisión de código

### Hallazgo crítico: el crossfade no se disparaba en el flujo natural de una playlist
La primera versión evaluaba las 4 condiciones del crossfade (setting > 0, pista nueva local, pista
actual también local, motor reproduciendo) dentro de `_playCurrentInternal()`, invocado únicamente
cuando el usuario saltaba de pista (a mano, o vía `_onComplete()` tras el fin natural). Dos
problemas de fondo:

1. Al llegar al fin natural de una pista, el motor ya reporta `playing: false` en el mismo momento
   en que emite el evento de fin — para cuando `_onComplete()` → `skipToNext()` →
   `_playCurrentInternal()` llegaban a evaluar la condición 4, siempre era falsa.
2. Aunque no lo fuera: un crossfade real tiene que **empezar antes** de que la pista saliente
   termine, superponiendo el final de una con el principio de la otra — reaccionar *después* del
   final no deja nada que desvanecer.

**Fix — disparador preventivo:** `_onEngineState()` (que ya recibe cada tick de posición del motor)
ahora llama a `_maybeCrossfadeProactively()` en cada tick. Si la pista actual es local, hay
crossfade configurado, el motor está reproduciendo, y `duration - position` ya cayó por debajo (o
igual) de la duración configurada, se dispara la transición — sin que el usuario haga nada. Un
`(SyncoraTrack, QueueOrigin)? _peekNext()` nuevo (de solo lectura, sin mutar `_state`) espía cuál
sería la próxima pista con la misma prioridad manual-antes-que-auto que ya usaba `_advance()`;
ambos comparten esta única función para no duplicar la lógica de prioridad. Un flag
`_crossfadeAttemptedForTrackId` (comparado contra `_state.currentTrack?.id` en cada tick, en vez de
resetearse a mano en cada sitio que cambia `currentTrack`) evita reintentar en cada tick mientras
el intento async (verificar si la siguiente está descargada) sigue en vuelo.

La duración real del fade usada en el disparo preventivo es el **mínimo entre la configurada y lo
que en verdad queda de la pista saliente** en ese instante — así el fade termina exactamente cuando
la pista vieja habría terminado de forma natural, sin que el motor saliente llegue a su propio EOF
a mitad del fade. El camino de skip **manual** (usuario toca "siguiente" con tiempo de sobra) sigue
usando la duración configurada completa, sin cambios.

La mutación de avance (`_advance()`) se refactorizó para compartir `_peekNext()` y un nuevo
`_commitAdvanceTo(track, origin)` — este último remueve la pista de su cola de origen **por id**, no
por posición, porque el crossfade preventivo puede tardar (el chequeo de descarga es async) y la
cola pudo reordenarse desde la pantalla de Cola mientras tanto.

### Bugs de implementación corregidos en `CrossfadeAudioEngine`

1. **`Future` que nunca completaba** (crítico — dejaba el botón "siguiente" muerto hasta reiniciar
   la app): el diseño original usaba un `Completer` que solo se completaba en el camino "el timer
   corrió todos sus pasos". Rediseñado: el ramp de volumen ahora corre en un método interno
   (`_runBackgroundFade`) con su propio `Completer`, completado **siempre** en un bloque `finally`
   — cubriendo fin normal, invalidación por una llamada nueva, e invalidación por `dispose()`.
2. **El controlador quedaba bloqueado por toda la duración del fade**: `crossfadeToLocalSource`
   ahora resuelve **rápido** — solo espera a que el motor entrante quede cargado, reproduciendo, y
   a que el swap de cuál instancia es `_active` se decida. El ramp de volumen (pasos de 50ms) sigue
   corriendo en segundo plano (`unawaited`), sin bloquear al llamador — el guard `_isTransitioning`
   del controlador ya no queda inutilizable por 2-6 segundos en cada transición local-a-local.
3. **`_standby` perdía velocidad/Skip Silence, y el swap forzaba el volumen a 1.0**: el wrapper
   ahora recuerda los últimos valores "canónicos" pedidos vía `setSpeed`/`setSkipSilenceEnabled`/
   `setVolume` y se los aplica a `_standby` antes de que empiece a sonar; el ramp de volumen termina
   en el volumen canónico del usuario, nunca fijo a 1.0.
4. **Los streams del wrapper seguían apuntando al motor saliente durante todo el fade**: el swap
   (`_active`/`_standby` + resuscripción) ahora ocurre de inmediato al arrancar el fade, no al
   terminar — la barra de progreso/posición reflejan la pista entrante desde el arranque, y para
   cuando el motor saliente llega a su EOF natural (con el disparo preventivo, esto pasa casi
   exactamente al final del fade, por diseño) el wrapper ya no escucha sus streams, así que ese
   evento no se propaga como una finalización espuria.
5. **`Timer.periodic` con callback `async` podía solapar pasos**: reemplazado por un bucle
   secuencial (`while` + `await Future.delayed(...)` entre pasos), que garantiza que un paso nunca
   arranca antes de que el anterior termine de escribir ambos volúmenes.
6. **`_currentPlaybackIsLocal` no se reseteaba en caminos de error/reintento**: ahora se resetea
   explícitamente a `false` al principio de CADA intento de reproducción en `_playCurrentInternal`
   (antes de decidir el camino), no solo se actualiza en los caminos de éxito.

---

## 📑 Verificación de pruebas automatizadas

- `flutter analyze`: limpio (solo lints `info` preexistentes, mismo patrón que ya tenían los demás
  campos inyectados por getter del controlador).
- `flutter test`: suite completa pasa (276 tests). Nuevo/actualizado:
  - `test/features/player/audio_engine/crossfade_audio_engine_test.dart` (10 tests): delegación
    normal sin crear `_standby`; `crossfadeToLocalSource` resuelve rápido (no bloquea por la
    duración del fade) y ya deja a `_standby` cargando/reproduciendo; el `stateStream`/posición
    reflejan la pista entrante desde el arranque del fade, no recién al final; los volúmenes de
    ambos motores se mueven en direcciones opuestas durante el ramp en segundo plano; el motor
    saliente recibe `stop()` al terminar; velocidad/Skip Silence/volumen configurados se preservan
    en el motor entrante tras el swap; el motor viejo se reutiliza sin recrearse; una segunda
    llamada solapada con el ramp de la primera todavía en vuelo no deja ningún `Future` colgado
    (con timeout explícito en el test); `dispose()` a mitad de un fade no deja nada pendiente.
  - Grupo `syncora_player_controller_test.dart` ("crossfade (Fase 7.D)", 7 tests): las 4 originales
    (decisión manual: usa `crossfadeToLocalSource` cuando corresponde; transición normal si el
    setting está "off", la siguiente no está descargada, o la actual vino de streaming) más 3
    nuevas para el disparador preventivo: se dispara solo (sin ningún skip manual) cuando el tiempo
    restante cae bajo el umbral; no se duplica para la misma pista con ticks repetidos; usa como
    duración real del fade el mínimo entre la configurada y lo que en verdad queda de la pista.
  - Se agregó tracking de llamadas a `FakeAudioEngine` (`setLocalSourceCallCount`, `playCallCount`,
    `stopCallCount`, `setSpeedCallCount`, `lastSkipSilence`/`setSkipSilenceCallCount`,
    `lastLocalSourcePath`, y el stub de `crossfadeToLocalSource` con
    `crossfadeCallCount`/`lastCrossfadePath`/`lastCrossfadeDuration`) para poder verificar
    delegación exacta; se reutiliza esa misma clase (definida en
    `syncora_player_controller_test.dart`) desde el archivo de test nuevo vía
    `import '../syncora_player_controller_test.dart' show FakeAudioEngine;`.
  - `CrossfadeAudioEngine` expone `debugAwaitFadeSettled()` (fuera del contrato `AudioEngine`,
    solo para tests) para esperar de forma determinista a que el ramp en segundo plano termine, sin
    depender de temporizadores reales arbitrarios.
  - `mini_player_test.dart` tiene su propia copia de `FakeAudioEngine` (no importa la de arriba) —
    tiene el mismo stub mínimo del método nuevo para que siga compilando.

## 🧑‍🔬 Pendiente — prueba humana obligatoria (7.D.6)

No verificable por el agente (requiere oído real) — **más importante que nunca dado el alcance de
este rediseño**: toda la lógica de disparo se validó con fakes y aserciones de estado, nunca con
audio real. Matriz de pruebas (`docs/matriz_de_pruebas.md`, sección "Humano (Rápido)"): **activar
Crossfade en una pista descargada en Windows y verificar que la transición suena bien; repetir la
prueba en Android.**

Pasos sugeridos:
1. En Configuración, fijar la duración de crossfade en 4s o 6s.
2. Descargar 2-3 pistas consecutivas de una misma playlist/álbum.
3. Reproducir la playlist y dejarla sonar **sin tocar nada** — la transición entre la primera y la
   segunda pista debe crossfade-ar sola, unos segundos antes del final de la primera (caso
   principal, antes roto).
4. Además, probar el skip manual: tocar "siguiente" con tiempo de sobra en la pista actual también
   debe crossfade-ar (con la duración configurada completa, no la recortada del paso 3).
5. Repetir con una pista SIN descargar de por medio para confirmar que ahí NO hay crossfade
   (transición normal, sin fade).
6. Ajustar el volumen manualmente justo antes de una transición y confirmar que la pista entrante
   no "salta" a volumen máximo al terminar el fade (debe respetar el volumen configurado).
7. Caso límite de bajo riesgo, no bloqueante pero vale la pena escuchar: una playlist donde la
   pista **siguiente-a-la-siguiente** de una que sí crossfade-a NO está descargada. El disparador
   preventivo ya arrancó el crossfade hacia la pista 2 (con el swap interno ya hecho) cuando,
   casi al mismo tiempo, la transición normal hacia la pista 3 (sin descarga) podría interrumpir
   abruptamente el fade-in que seguía en curso en segundo plano. El estado de la cola queda
   correcto en todos los casos (verificado por revisión de código), pero el resultado *audible* en
   ese instante puntual no se probó con audio real — si suena raro, es un candidato a reportar,
   no algo ya descartado.
