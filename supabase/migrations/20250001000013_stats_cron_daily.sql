-- Programa `aggregate_monthly_listening_stats()` a diario (H-S8).
--
-- POR QUÉ DIARIO Y NO MENSUAL
-- El cron original corría el día 1 de cada mes y agregaba solo meses ya
-- cerrados. Como las vistas largas (6 meses, 12 meses, "Desde el inicio") se
-- arman con `user_stats_monthly`, el mes en curso no aparecía en ninguna de
-- ellas hasta el mes siguiente. La función ya recalcula el mes actual de
-- forma idempotente (migración 12), así que basta con correrla a diario.
--
-- La poda de 90 días vive dentro de la misma función y se ejecuta DESPUÉS de
-- agregar, así que pasar a diario no adelanta ningún borrado: lo que se
-- borra ya está agregado.
--
-- Esto era hasta ahora un paso manual pendiente documentado en
-- docs/fases/fase_7_g.md (junto con habilitar la extensión desde el
-- Dashboard). Se automatiza acá, pero de forma defensiva: si la extensión no
-- se puede crear con los permisos de la conexión de migraciones, la
-- migración NO falla -- avisa y deja el paso manual pendiente, en vez de
-- bloquear el resto del despliegue.
DO $$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron no disponible (%): habilitala desde Dashboard > Database > Extensions y reaplica esta migracion.', SQLERRM;
    RETURN;
  END;

  -- El job mensual anterior queda obsoleto: la función ahora cubre todos los
  -- meses pendientes en cada corrida, así que dos jobs solo duplicarían
  -- trabajo.
  BEGIN
    PERFORM cron.unschedule('aggregate-monthly-stats');
  EXCEPTION WHEN OTHERS THEN
    NULL; -- no existía; nada que quitar
  END;

  BEGIN
    PERFORM cron.unschedule('aggregate-listening-stats-daily');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  -- 05:10 UTC: fuera de las horas de uso habituales y con margen respecto a
  -- cualquier otro job que arranque en punto.
  PERFORM cron.schedule(
    'aggregate-listening-stats-daily',
    '10 5 * * *',
    'SELECT public.aggregate_monthly_listening_stats()'
  );
END;
$$;
