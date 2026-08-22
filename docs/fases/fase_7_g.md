# Syncora Player — Fase 7.G: Estadísticas y Wrapped

## Resumen

Última fase de la Fase 7. Pantalla de Estadísticas con 4 vistas (Semanal, Mensual, Anual, Desde el
inicio) según D-17/D-18, tarjetas Wrapped compartibles como imagen (D-20), y gating de modo local
(7.I.6): en modo local solo existen Semanal y Mensual, sobre `listening_history` crudo — Anual y
Desde el inicio dependen de `user_stats_monthly`, que solo se llena en la nube vía un cron mensual
de Postgres.

## Componentes

- **`supabase/migrations/20250001000010_user_stats_monthly.sql`** (nuevo):
  - Tabla `user_stats_monthly` (`user_id`, `month_start`, `total_minutes`, `top_artists`/
    `top_tracks` JSONB con `{id, minutes}` top 50, `top_genres` JSONB con `{genre, minutes}`), PK
    compuesta `(user_id, month_start)`. RLS con solo `SELECT` propia (`auth.uid() = user_id`) — sin
    `INSERT`/`UPDATE`/`DELETE` para `authenticated`, solo escribe la función del cron.
  - Función `aggregate_monthly_listening_stats()`, `SECURITY DEFINER`: agrega el mes calendario
    recién cerrado (UTC) para todos los usuarios con historial en ese rango en un solo `INSERT ...
    SELECT` con `LEFT JOIN LATERAL` (una subconsulta por usuario para artistas/canciones/géneros,
    cada una con su propio `LIMIT 50` antes del `jsonb_agg`, sin loop `FOR user IN ...` explícito),
    y **recién después** poda `listening_history` a más de 90 días — el orden importa (D-19/7.G.2),
    nunca al revés.
  - `REVOKE ... FROM authenticated, anon, public` (mismo patrón que `before_user_created_account_
    limit` de 7.H): solo el rol que corre el cron puede invocarla, nunca el cliente.
  - **No incluye la llamada real a `cron.schedule(...)`** — requiere la extensión `pg_cron`
    habilitada desde el Dashboard (paso manual de proyecto, ver sección de pendientes abajo), mismo
    motivo que la activación del hook de 7.H.
- **`lib/features/stats/stats_calculator.dart`** (nuevo) — lógica de agregación pura, sin
  dependencias de Drift/Riverpod/Supabase (mismo patrón que `computeCanEdit`/`computeAuthRedirect`
  de 7.I): `StatsCalculator.fromRawEntries` (Semanal/Mensual, sobre datos crudos ya filtrados por
  ventana) y `StatsCalculator.rollupMonthlyRows` (Anual/Desde el inicio, suma filas de
  `user_stats_monthly` mergeando por id de artista/canción/género). `weekCutoff`/`monthCutoff` como
  funciones puras del cutoff de fecha, testeables sin Drift real.
- **`lib/data/local_db/daos/listening_history_dao.dart`** — nuevo método `getEntriesSince(DateTime
  cutoff)`: a diferencia de `getTopArtistIds` (que muestrea las últimas 100 entradas), Estadísticas
  necesita exactitud sobre la ventana completa de 7/30 días, sin límite artificial.
- **`lib/data/supabase/supabase_stats_repository.dart`** (nuevo) — `fetchMonthlyStats({int?
  limitMonths})`, mismo patrón de guarda de nulo que `SupabaseHistoryRepository` (`_isTestEnv`,
  `_client` con try/catch). `limitMonths: 12` para Anual (D-18: ventana móvil, no año calendario);
  sin límite para Desde el inicio.
- **`lib/features/stats/stats_providers.dart`** (nuevo) — `weeklyStatsProvider`,
  `monthlyStatsProvider`, `yearlyStatsProvider`, `allTimeStatsProvider`, más
  `enrichedArtistsProvider`/`enrichedTracksProvider` (`FutureProvider.family`) que resuelven
  nombre/portada contra `DeezerApi.getArtist`/`getTrack` en paralelo, descartando en silencio los
  IDs que fallen — mismo patrón que `personalizedSectionsProvider` de `home_providers.dart`.
- **`lib/features/stats/screens/stats_screen.dart`** (nuevo), ruta `/stats` registrada en
  `app_router.dart` dentro del `ShellRoute`: 3 pestañas (Semanal/Mensual/Anual) + "Ver desde el
  inicio" bajo demanda desde la pestaña Anual. En modo local, la pestaña Anual se reemplaza por un
  aviso ("Disponible solo con cuenta") en vez de dejarla rota. Empty state y skeleton de carga
  (`SkeletonBox`) en las 4 vistas. Tarjetas Wrapped tipo stories (`PageView` de 5 tarjetas dentro de
  `_WrappedStoriesScreen`), cada una en un `RepaintBoundary` con botón "Compartir" que captura PNG
  (`toImage`/`toByteData`) y lo comparte con `share_plus` (`Share.shareXFiles`) — solo imagen, sin
  URL pública (D-20).
- **`lib/features/home/screens/home_screen.dart`** — tarjeta compacta "Tus minutos esta semana: X —
  Ver más" (7.G.6), reusa `weeklyStatsProvider` (no duplica la query); no se muestra si el usuario
  no tiene datos todavía, para no meter ruido visual en el primer uso.
- **`test/features/stats/stats_calculator_test.dart`** (nuevo) — 11 tests: cutoffs de 7/30 días,
  agregación de minutos/artistas/canciones/géneros, `topN` respetado (recorta, no rellena), lista
  vacía, IDs inválidos (0) ignorados sin romper el total, suma de 12 filas mensuales sin duplicar
  artistas repetidos entre meses, caso de menos de 12 meses de historial, y `mostActiveMonth`
  eligiendo la fila individual de mayor total (no la suma).

## Revisión

Sin invariantes de riesgo real (no toca `syncora_player_controller.dart`/cola ni auth) — revisado
por el propio orquestador leyendo el diff completo directamente, sin subagente de revisión
separado, siguiendo el mismo criterio ya aplicado en 7.F.3/7.F.4. Sin hallazgos que corregir: el
guardado de nulo del repositorio Supabase sigue el patrón existente, el orden agregación-antes-de-
podar de la función SQL es correcto, el gating de modo local en la pantalla oculta (no deshabilita)
la pestaña Anual como pide 7.I.8, y la migración replica el estilo de comentarios/GRANT-REVOKE de
7.H.

Un detalle menor aceptado a propósito, sin corrección: `enrichedArtistsProvider`/
`enrichedTracksProvider` son `FutureProvider.family<..., List<StatEntry>>` — como `StatEntry` no
sobreescribe `==`, cada rebuild con una lista "igual mano" en valores crea una nueva instancia de
provider en vez de reusar caché. No es un bug de corrección (los datos mostrados son siempre
correctos), solo una recarga de red innecesaria en algunos rebuilds; no amerita la complejidad de
agregar `==`/`hashCode` a `StatEntry` para una pantalla que no se refresca con frecuencia.

## Verificación de pruebas

- `flutter analyze`: limpio (28 lints `info` preexistentes, mismo baseline que el resto de la Fase
  7 — sin relación con este trabajo).
- `flutter test`: **343 tests, 0 fallos** (suite completa, una sola corrida antes de comitear — 332
  del baseline + 11 nuevos de `test/features/stats/stats_calculator_test.dart`).

## Pendiente / pasos manuales para el desarrollador humano

Igual que el resto de la infraestructura de Supabase de esta fase (Edge Functions de 7.E, hook de
7.H), **programar el cron es configuración de proyecto, no viaja en las migraciones**:

1. Aplicar la migración `20250001000010_user_stats_monthly.sql` (`supabase db push` o equivalente).
2. Dashboard de Supabase → **Database → Extensions** → habilitar `pg_cron`.
3. En el SQL Editor, correr una sola vez:
   ```sql
   SELECT cron.schedule(
     'aggregate-monthly-stats',
     '0 5 1 * *',
     'SELECT public.aggregate_monthly_listening_stats()'
   );
   ```
4. La sintaxis de la función (el `LEFT JOIN LATERAL` con tres subconsultas por fila de `base`,
   combinado con `LIMIT 50` interno y `ORDER BY` dentro de `jsonb_agg`) nunca se probó contra una
   base Postgres real, igual que las migraciones de 7.E/7.H en su momento — vale la pena correrla
   una vez manualmente (o revisar el plan de ejecución con `EXPLAIN`) antes de confiar en que
   produce el resultado esperado, sobre todo con datos reales de varios usuarios en el mismo mes.
5. Sin datos reales en `user_stats_monthly` (porque el cron nunca corrió en un proyecto real), las
   vistas Anual y Desde el inicio no se probaron contra Supabase real — solo la lógica de rollup
   está cubierta por tests (`stats_calculator_test.dart`). Vale la pena una prueba manual end-to-end
   una vez que el cron corra al menos un mes.

No hay test de widget para `StatsScreen` (solo la lógica pura de `StatsCalculator` tiene cobertura
automatizada) — mismo criterio que 7.F.3/7.F.4/7.I.13 (UI de bajo riesgo sin invariantes de
cola/auth). `SupabaseStatsRepository` tampoco tiene test, mismo caso que `SupabaseHistoryRepository`
(sin infraestructura de mock de Supabase en el proyecto para este tipo de repos).
