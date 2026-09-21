-- Corrige `stats_health()` (migración 14): `cron.job_run_details` no tiene
-- columna `jobname` -- solo `jobid`. La consulta fallaba y el manejador de
-- excepciones devolvía el error en lugar del listado de jobs, de modo que la
-- función no podía confirmar lo único para lo que existe.
CREATE OR REPLACE FUNCTION public.stats_health()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  has_cron BOOLEAN;
  jobs JSONB := '[]'::jsonb;
  last_runs JSONB := '[]'::jsonb;
BEGIN
  SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') INTO has_cron;

  IF has_cron THEN
    BEGIN
      EXECUTE $q$
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'jobid', jobid, 'jobname', jobname, 'schedule', schedule,
          'active', active, 'command', command)), '[]'::jsonb)
        FROM cron.job
      $q$ INTO jobs;
    EXCEPTION WHEN OTHERS THEN
      jobs := jsonb_build_object('error', SQLERRM);
    END;

    -- Separado del anterior: si falla la lectura del historial de corridas
    -- (cambia entre versiones de pg_cron), el listado de jobs -- que es el
    -- dato importante -- no debe perderse con él.
    BEGIN
      EXECUTE $q$
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'jobid', r.jobid, 'status', r.status, 'start_time', r.start_time,
          'return_message', r.return_message) ORDER BY r.start_time DESC), '[]'::jsonb)
        FROM (
          SELECT jobid, status, start_time, return_message
          FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5
        ) r
      $q$ INTO last_runs;
    EXCEPTION WHEN OTHERS THEN
      last_runs := jsonb_build_object('error', SQLERRM);
    END;
  END IF;

  RETURN jsonb_build_object(
    'pg_cron_installed', has_cron,
    'cron_jobs', jobs,
    'last_runs', last_runs,
    'raw_rows', (SELECT count(*) FROM public.listening_history),
    'raw_oldest', (SELECT min(listened_at) FROM public.listening_history),
    'raw_without_genre', (SELECT count(*) FROM public.listening_history WHERE genre IS NULL),
    'monthly_rows', (SELECT count(*) FROM public.user_stats_monthly)
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.stats_health FROM authenticated, anon, public;
GRANT EXECUTE ON FUNCTION public.stats_health TO service_role;
