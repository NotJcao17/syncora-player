-- =====================================================================
-- L0 - Verificacion del estado real de las estadisticas en Supabase.
-- Solo LEE, no modifica nada. Pegar entero en el SQL Editor y ejecutar.
-- =====================================================================

-- 1) Que tablas de estadisticas existen realmente
SELECT 'tabla' AS que, table_name AS valor
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('listening_history', 'user_stats_monthly', 'ai_rate_limits', 'app_config')
ORDER BY table_name;

-- 2) EL CRITICO (H-S9): existe el indice unico del que depende el upsert?
--    Si esta consulta NO devuelve 'idx_listening_history_dedup', entonces
--    insertListeningHistory() esta fallando SIEMPRE con error 42P10 y
--    NINGUNA escucha se ha subido nunca a la nube.
SELECT 'indice' AS que, indexname AS valor, indexdef
FROM pg_indexes
WHERE schemaname = 'public' AND tablename = 'listening_history';

-- 3) Existe la funcion de agregacion mensual, y esta programado el cron?
SELECT 'funcion' AS que, proname AS valor
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND proname = 'aggregate_monthly_listening_stats';

SELECT 'extension pg_cron' AS que, extname AS valor
FROM pg_extension WHERE extname = 'pg_cron';

-- (si pg_cron no esta instalado, la siguiente linea dara error: es esperable)
SELECT 'cron job' AS que, jobname AS valor, schedule, command FROM cron.job;

-- 4) Cuantos datos hay de verdad
SELECT 'filas listening_history' AS que, count(*)::text AS valor FROM public.listening_history;
SELECT 'filas user_stats_monthly' AS que, count(*)::text AS valor FROM public.user_stats_monthly;

-- 5) Salud de los datos existentes: cuantas escuchas quedaron congeladas
--    en el umbral (~30s, sintoma de H-S2) y cuantas tienen genero
SELECT
  count(*) AS total,
  count(*) FILTER (WHERE duration_listened_ms IS NULL)          AS sin_duracion,
  count(*) FILTER (WHERE duration_listened_ms BETWEEN 25000 AND 35000) AS congeladas_en_30s,
  count(*) FILTER (WHERE genre IS NOT NULL)                     AS con_genero,
  round(sum(duration_listened_ms) / 60000.0, 1)                 AS minutos_totales,
  min(listened_at)                                              AS mas_antigua,
  max(listened_at)                                              AS mas_reciente
FROM public.listening_history;

-- 6) Duplicados reales de la misma escucha (H-S3): misma pista, mismo
--    usuario, a menos de 1 minuto de distancia
SELECT count(*) AS pares_sospechosos FROM (
  SELECT user_id, track_id, listened_at,
         lag(listened_at) OVER (PARTITION BY user_id, track_id ORDER BY listened_at) AS anterior
  FROM public.listening_history
) s
WHERE anterior IS NOT NULL AND listened_at - anterior < interval '1 minute';

-- 7) Reparto por dia de los ultimos 14 dias: sirve para comparar contra
--    lo que la app te muestra y contra lo que recuerdas haber escuchado
SELECT date_trunc('day', listened_at)::date AS dia,
       count(*) AS escuchas,
       round(sum(duration_listened_ms) / 60000.0, 1) AS minutos
FROM public.listening_history
WHERE listened_at > now() - interval '14 days'
GROUP BY 1 ORDER BY 1 DESC;
