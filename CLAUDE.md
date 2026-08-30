# Instrucciones para agentes en este repositorio

Antes de trabajar en cualquier tarea, leer **`docs/Documento_Maestro.md`** completo — es la fuente
de verdad de arquitectura, stack, metodología de trabajo y reglas del proyecto. No es opcional. Es el documento inicial, así que pudo haber sufrido cambios, pero estarían documentados en los documentos de fase.

## Reglas de Git (estrictas — ver Documento_Maestro.md, sección 1)

- Los commits llevan **solo mensaje/subject, sin cuerpo ni descripción extendida**.
- **Nunca** agregar `Co-authored-by` ni ninguna otra atribución de autoría del agente/IA a los commits.
- Al finalizar y validar cada fase de trabajo, el agente hace `git push` al remoto — no hace falta
  pedir confirmación para ese push normal (ya autorizado por esta regla). Esto **no** cubre
  operaciones destructivas o de reescritura de historia (`push --force`, `reset --hard`, etc.), que
  siempre requieren confirmación explícita del usuario en el momento, como en cualquier repo.

## Metodología de ejecución de la Fase 7 (orquestador + subagentes)

Mientras se ejecute `docs/plan_fase_7.md`, esta metodología aplica y **sobrevive a cualquier
`/compact` o sesión nueva** — si la memoria de la conversación se pierde, re-leer esta sección
y el plan basta para retomar sin perder nada importante:

- **Orden de fases:** estricto, el que define el plan (7.0 → 7.A → ... → 7.G). No reordenar ni
  paralelizar fases que dependen entre sí.
- **Un subagente por fase**, con contexto acotado a esa fase (no el plan completo).
- **Modelos:** Sonnet, effort medium.
- **Revisión independiente obligatoria** entre fases (subagente de `code-review` separado del que
  implementó), antes de dar la fase por cerrada.
- **Tests automatizados como gate de cada fase** — no pruebas manuales a medio camino; las
  manuales de `docs/matriz_de_pruebas.md` se agrupan al final de toda la Fase 7.
- **Marcar los checkboxes `[x]`** de `docs/plan_fase_7.md` a medida que se completan, y comitear
  seguido (no solo al cerrar la fase entera) — es la fuente de verdad de progreso, más confiable
  que la memoria de la conversación. Si aparece un hallazgo que cambia el plan, documentarlo ahí
  con el mismo formato de "hallazgo verificado" que ya usan H-1 a H-5, no aplicarlo en silencio.
- **Cuándo parar y preguntar al usuario:** decisión de diseño no cubierta por el plan, algo que
  una revisión de código no puede resolver con confianza, o cualquier acción destructiva/
  irreversible. Fuera de eso, seguir de fase en fase sin esperar aprobación en cada una.

### Eficiencia de tokens (agregado tras cerrar 7.F.1/7.F.2 — el ritmo de esas dos fases no es
sostenible, consumieron ~80% de una ventana de 5 horas)

Cada subagente arranca en frío y re-lee una porción del repo antes de hacer nada — ese costo fijo
se paga cada vez que se lanza uno. 7.F.1 y 7.F.2 lanzaron un agente implementador + un agente de
revisión independiente por sub-bloque (uno de ellos incluso se relanzó por un error de
`isolation: "worktree"` que no ve cambios sin commitear — un run entero desperdiciado), más
numerosas corridas de la suite completa de tests. Total: tres llamadas a subagente ya sumaron solo
ellas más de 550k tokens, sin contar el trabajo del orquestador. Para el resto de la Fase 7:

- **Revisión independiente solo para riesgo real, no por sub-bloque.** Reservar un subagente de
  revisión separado para
  cambios que toquen invariantes de riesgo real: cola manual/automática (D-1), auth, o lo que la
  Edge Function escribe/valida server-side. Para UI o lógica de bajo riesgo (ej. el modo "quitar"
  de 7.F.3, restringido por schema a IDs existentes — D-7 — así que estructuralmente no puede
  inventar nada; o 7.F.4 completa), el propio orquestador revisa el diff directamente leyendo los
  archivos, como se hizo con 7.E, en vez de lanzar otro agente.
- **Agrupar sub-bloques pequeños en una sola tanda de implementación**, en vez de un round-trip de
  agente por cada uno — 7.F.3 y 7.F.4 son buenos candidatos a implementarse juntos.
- **Un solo `flutter test` completo por fase, justo antes de comitear.** Durante la iteración/
  debugging, correr solo el archivo de test específico que se está arreglando
  (`flutter test test/ruta/al/archivo_test.dart`), nunca la suite entera repetidamente. Recordar
  también el bloqueo de Windows: nunca dos invocaciones de `flutter test`/`flutter analyze`/
  `flutter build` en paralelo (colisionan por un lock real sobre `sqlite3.dll` en
  `build\native_assets\windows\`) — esperar a que una termine antes de lanzar la siguiente, no
  reintentar en un loop.

### Estado actual (última actualización: 2026-08-22)

**Fase 7 completa.** Cerradas, commiteadas y pusheadas a `master` (ver
`docs/fases/fase_7_{0,a,b,c,d,e,f,g,h,i}.md` para el detalle de cada una): **7.0, 7.A, 7.B, 7.C,
7.D, 7.E, 7.F.1, 7.F.2, 7.F.3, 7.F.4, 7.H, 7.I, 7.G**. Todas con `flutter analyze` limpio y la
suite de tests en verde en el momento de cerrarlas (343 tests al cerrar 7.G — 332 al cerrar 7.I;
+11 en 7.G).

7.G ("Estadísticas y Wrapped") fue la última fase del plan. Pantalla de Estadísticas con 4 vistas
(Semanal/Mensual sobre `listening_history` crudo; Anual/Desde-el-inicio sobre el nuevo agregado
`user_stats_monthly`, D-17), gateada por modo local según 7.I.6 (Anual y Desde-el-inicio ocultas,
no deshabilitadas, sin cuenta), tarjetas Wrapped tipo stories compartibles como imagen (D-20), y
entrada resumida desde Inicio (7.G.6). Toda la lógica de agregación vive en funciones puras
testeables (`StatsCalculator.fromRawEntries`/`rollupMonthlyRows`, mismo patrón que
`computeCanEdit`/`computeAuthRedirect` de 7.I), sin invariantes de riesgo real (no toca cola ni
auth), así que se revisó por el propio orquestador leyendo el diff directamente, sin subagente de
revisión separado — mismo criterio que 7.F.3/7.F.4. Sin hallazgos que corregir. Detalle completo en
`docs/fases/fase_7_g.md`, incluido el SQL exacto de `cron.schedule(...)` pendiente de correr
manualmente una vez habilitada la extensión `pg_cron` desde el Dashboard (mismo patrón de paso
manual que el hook de 7.H y la Edge Function de 7.E) — la función de agregación
(`aggregate_monthly_listening_stats()`, con `LEFT JOIN LATERAL` por usuario) nunca corrió contra
Postgres real, vale la pena revisarla antes de confiar en el cron en producción.

7.I (modo local / sin cuenta, D-23 a D-25) fue la fase de mayor superficie de la Fase 7 hasta
ahora — toca `auth`, routing, y gating de edición en ~6 pantallas. Revisión independiente en
**Opus** con effort alto (excepción pre-aprobada explícitamente por el plan solo para esta fase).
Encontró **3 hallazgos P0 de pérdida de datos real**, ya corregidos: la migración local → cuenta
no subía álbumes guardados, así que el primer `syncLibrary` tras crear la cuenta los podaba por
completo; `createPlaylist(isLiked: true)` a ciegas podía crear una segunda "Tus me gusta" al
iniciar sesión en una cuenta ya existente, con el dedup del sync borrando arbitrariamente una de
las dos (corregido con `getOrCreateLikedPlaylist`); y el modo local podía quedar "pegado" (con
sesión real pero flag de modo local todavía en `true`, sin salida) si la app crasheaba a mitad de
migrar (corregido con autocorrección en `main.dart` al siguiente arranque). Más 3 P1 (reentrancia
de la migración, duplicado de playlist en un reintento tras fallo parcial, 4 entradas de IA que
seguían visibles fuera de `library_screen.dart`) y 1 P2 cosmético, todos corregidos. Desviación
deliberada del plan: 7.I.5 (sync no-op) se cortó en los puntos de disparo de la UI en vez de en
`SyncService`, porque tocar ese servicio rompía los tests existentes que lo llaman directamente con
repos mockeados. Detalle completo en `docs/fases/fase_7_i.md`.

7.H (límite de 250 cuentas, D-22) tocó `auth` — categoría de riesgo real de la metodología — así
que sí se lanzó un subagente de revisión independiente (Sonnet), a diferencia de 7.F.3/7.F.4.
Encontró y ya se corrigió: un hueco real donde el rechazo del hook por cupo lleno (y cualquier
otro error de OAuth) desaparecía en silencio en Android/iOS porque el resultado de
`signInWithOAuth` ahí llega por un deep link fuera de `auth_screen.dart` (corregido con un bridge
nuevo, `auth_deep_link_errors.dart`); un fail-open en la función SQL del hook si la fila de
`app_config` llegara a faltar (corregido con fallback a 250); y una nota documentada (sin cambio de
código) sobre el acoplamiento del mensaje genérico de error de hooks si se agrega un segundo hook
en el futuro. El botón "usar sin cuenta" que el plan original pedía junto al mensaje de cupo lleno
se dejó deliberadamente fuera: 7.I (modo local) todavía no existe en el código en este punto, así
que no hay destino real al que apuntar — se cablea en 7.I.3. Detalle completo en
`docs/fases/fase_7_h.md`.

7.F.1 ("Crear playlist con IA") quedó con 3 bugs reales encontrados y corregidos por el
orquestador antes de la revisión (churn de suscripciones Drift por crear un `Stream` inline en
cada rebuild, un `Timer` interno de Drift que quedaba pendiente en tests sin
`closeStreamsSynchronously`, y `FlutterSecureStorage` real colgando un test por no mockear
`aiKeyStorageProvider`), más 4 hallazgos de la revisión independiente (Sonnet) ya corregidos: falta
de cobertura de test en el camino exitoso (agregada), doble-tap posible en "Crear con IA"
(agregado flag `_isSubmitting`), mensaje de validación que prometía más de lo que exigía (agregado
`_hasAnyParamSet`), y un carácter soft-hyphen suelto en `prompts.ts`.

7.F.2 ("Crear cola con IA") se implementó reusando piezas de 7.F.1 (widgets de progreso/vista
previa extraídos a `lib/core/widgets/ai_generation_steps.dart`, compartidos por ambas). Su
revisión independiente fue en **Opus** (no Sonnet) porque toca `syncora_player_controller.dart` —
mismo criterio de riesgo que justificó Opus para 7.A. Encontró y ya se corrigió: un borde real
donde `interleaveIntoAutoQueue` podía violar D-1 (promovía una pista de la cola manual a "sonando
ahora" tras restaurar una sesión con `currentTrack` null y `manualQueue` no vacía — cubierto con un
test dedicado, para lo que el controller ganó un `sessionStorage` inyectable solo para tests); el
paso de intercalado "cada 3" fijo del plan dejaba las sugerencias sobrantes en un bloque al final
en el caso de uso principal, corregido a paso adaptativo (**hallazgo H-8** en
`docs/plan_fase_7.md`); y 3 P2 menores (`ref.read` antes de chequear `mounted` en ambos archivos
7.F.1/7.F.2, `addPostFrameCallback` sin guarda de `mounted`, muestreo de contexto que podía
descartar la pista actual). Detalle completo de ambos sub-bloques en `docs/fases/fase_7_f.md`.

7.F.3 ("Modificar playlist con IA") y 7.F.4 ("Buscar canción por fragmento de letra") se
implementaron juntas en una sola tanda (metodología de eficiencia de tokens, ambas son chicas) y
revisadas por el propio orquestador leyendo el diff directamente, sin subagente de revisión
separado — ninguna toca invariantes de riesgo real (D-1/cola o auth). Antes de implementarlas se
extrajo el parseo `result['tracks']`/`result['songs']` y el recorte D-5 a la cantidad exacta
(duplicados casi línea por línea en 7.F.1/7.F.2) a dos métodos estáticos nuevos en
`playlist_import_export_service.dart` (`parseTrackSuggestions`, `trimToCount`), usados ahora por
las 4 hojas de IA — el resto del esqueleto (`setState`/`mounted`/manejo de pasos) se dejó sin
abstraer, es puro cableado de UI con más costo de abstracción que ahorro real. Sin bugs encontrados
en la revisión de este sub-bloque. Detalle completo en `docs/fases/fase_7_f.md`.

**La Fase 7 está completa — no queda ninguna fase pendiente de implementar en `docs/plan_fase_7.md`.**
Lo que sigue son pasos manuales de infraestructura (ver abajo) y las pruebas humanas de
`docs/matriz_de_pruebas.md`.

**Hallazgos verificados durante la Fase 7 que no estaban en el plan original** (ya documentados
como H-6 a H-8 en `docs/plan_fase_7.md`, sección de hallazgos — no volver a descubrirlos): el aviso
visual del guard 403/red de Fase 1 nunca tenía consumidor en la UI (arreglado en 7.C); el modelo
Gemini y la forma de llamar a su API cambiaron desde que se escribió el plan — usar
`gemini-3.5-flash-lite` sobre la API de Interactions (`v1beta/interactions`), no
`gemini-3.1-flash-lite`/`generateContent` (ya implementado así en 7.E); el intercalado "cada 3"
fijo de 7.F.2 (D-9) dejaba las sugerencias sobrantes en bloque, corregido a paso adaptativo.

**Pasos manuales acumulados, pendientes para el desarrollador humano** (ninguno bloquea el trabajo
de código, pero hacen falta para probar la Fase 7 de punta a punta contra Supabase real):
aplicar las migraciones `20250001000008_ai_rate_limits.sql` a `...000010_user_stats_monthly.sql`
(no aplicadas todavía contra un proyecto real); desplegar la Edge Function (`supabase functions
deploy ai-assistant`), configurar el secreto `GEMINI_API_KEY`, y correr `deno test`/`deno check`
sobre `supabase/functions/ai-assistant/` (Deno no está disponible en el entorno del agente, esos
tests nunca se ejecutaron, solo se escribieron) — detalle en `docs/fases/fase_7_e.md`; activar el
Auth Hook "Before User Created" de 7.H en el dashboard y probar ambos caminos de registro contra un
proyecto real — detalle en `docs/fases/fase_7_h.md`; habilitar `pg_cron` y programar
`aggregate_monthly_listening_stats()` de 7.G (SQL exacto en `docs/fases/fase_7_g.md`), cuya
sintaxis (`LEFT JOIN LATERAL` por usuario) tampoco corrió nunca contra Postgres real. También sigue
pendiente 7.D.6 (prueba humana de crossfade en Windows y Android, ver `docs/fases/fase_7_d.md`).

## Otros documentos relevantes

- `docs/plan_fase_7.md` — plan y decisiones de diseño de la **Fase 7** (cola dual, radio/cola
  infinita, funciones de IA con Gemini, auto-skip, crossfade, estadísticas Wrapped). Leer antes de
  tocar cualquier cosa de la Fase 7.
- `docs/plan_buscador_importacion_matcher.md` — plan y estado del buscador/importación/matcher de
  YouTube (Fases 0/A/B/C/D).
- `docs/fases/` — documentos de contexto y decisiones de arquitectura por fase.
- `docs/fuentes_youtube_y_matching.md` — cuándo se usa YouTube y cuándo YouTube Music como
  fuente de candidatos, cómo se rankean (`YtSearchMatcher`) y por qué las portadas de Deezer a
  veces son de una recopilación. Leer antes de tocar `lib/core/extraction/`.
- `docs/matriz_de_pruebas.md` — matriz de pruebas manuales que el humano ejecuta.
