-- Chequeo de salud de las estadísticas, para operación.
--
-- Responde de un vistazo "¿está viva la agregación?": si `pg_cron` quedó
-- instalado, si el job diario existe, cuándo corrió por última vez y con qué
-- resultado, y cuántas filas hay a cada lado (crudo vs agregado mensual).
--
-- Hace falta porque el scheduling vive en un bloque `DO` que se traga los
-- errores a propósito (para no bloquear el despliegue si la extensión no se
-- puede crear), así que "la migración no falló" no prueba que el cron esté
-- programado. Sin esto la única forma de saberlo es entrar al Dashboard.
--
-- SECURITY DEFINER y **solo para service_role**: no expone datos de ningún
-- usuario, pero tampoco tiene por qué verlo la app.
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
          'jobname', jobname, 'schedule', schedule, 'active', active)), '[]'::jsonb)
        FROM cron.job
      $q$ INTO jobs;

      EXECUTE $q$
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'jobname', jobname, 'status', status, 'start_time', start_time,
          'return_message', return_message) ORDER BY start_time DESC), '[]'::jsonb)
        FROM (
          SELECT jobname, status, start_time, return_message
          FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5
        ) r
      $q$ INTO last_runs;
    EXCEPTION WHEN OTHERS THEN
      jobs := jsonb_build_object('error', SQLERRM);
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
