-- El agregado mensual solo escribe meses que siguen COMPLETOS en el historial
-- crudo (H-S12, docs/fases/rediseno_estadisticas.md).
--
-- EL BUG
-- `aggregate_monthly_listening_stats()` (migración 17, cron diario de la 13)
-- agrupaba TODAS las filas que quedaban en `listening_history` por usuario y
-- mes, hacía upsert de cada mes encontrado y después podaba lo de más de 90
-- días. Cuando la poda empieza a comerse un mes, cada corrida lo recalculaba
-- solo con las filas que le quedaban y SOBRESCRIBÍA el agregado completo con
-- uno más chico; al podarse su último día, `user_stats_monthly` se quedaba con
-- los totales y tops de ese día. Todo mes de más de ~90 días terminaba muy por
-- debajo de lo real en las vistas de 6 meses, 12 meses y "Todo". En
-- producción el historial empieza el 2026-08-30, así que el daño habría
-- empezado el 2026-11-28; se corrige antes de que ocurra.
--
-- EL ARREGLO
-- Un mes solo se escribe mientras su primer instante no haya pasado el corte
-- de retención (`month_start >= now() - 90 días`). Mientras eso se cumple no
-- se ha podado ni una fila suya (la poda borra `listened_at < corte` y el
-- corte solo avanza), así que la última escritura de cada mes es la del
-- último día en que estaba completo. Después queda congelado.
--
-- - Orden upsert → delete en una misma corrida: usan el MISMO corte. Lo que
--   se borra (`listened_at < corte`) pertenece a meses con
--   `month_start < corte`, que esta corrida ya no escribe. El orden deja de
--   importar.
-- - Un día sin cron (o varios): el mes M se sigue escribiendo en cualquier
--   corrida entre su cierre y `month_start + 90 días`, una ventana de ~59
--   días. Faltar a corridas no pierde nada mientras haya una en esa ventana:
--   la poda nunca toca un mes antes de dejar de escribirlo.
-- - Filas que llegan tarde (un dispositivo que sincroniza semanas después):
--   cuentan si llegan antes de que su mes salga de la ventana; si no, la poda
--   las borra sin agregarlas. Igual que antes: tampoco se agregaban.
--
-- POR QUÉ NO "NUNCA DISMINUIR total_ms" EN EL ON CONFLICT
-- Se evaluó y se descartó, también como capa extra:
-- - Es una heurística sobre un indicador, no la condición real. Bloquearía
--   correcciones legítimas que bajan el total: la limpieza de filas
--   congeladas de agosto (ver la sección "Limpieza de datos") hubo que
--   recalcularla a la baja, y lo mismo pasaría con cualquier depuración de
--   duplicados futura.
-- - Mezcla estados: durante la poda de un mes, una fila que llega tarde puede
--   subir el total de lo que queda por encima del agregado guardado, y el
--   upsert pasaría con tops e histograma de un mes a medias.
-- - Sigue recalculando a diario meses que ya no pueden cambiar. El corte por
--   mes completo dice exactamente qué meses son confiables y además ahorra
--   ese trabajo.
--
-- Todo lo demás queda igual que en la migración 17: top de canciones por
-- reproducciones, LIMIT 30/30/20/20, histograma hora×día y las mismas
-- columnas.
CREATE OR REPLACE FUNCTION public.aggregate_monthly_listening_stats()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- Un solo corte para el upsert y la poda (`now()` ya es fijo dentro de la
  -- transacción, pero así la relación entre los dos queda escrita).
  v_cutoff TIMESTAMPTZ := now() - interval '90 days';
BEGIN
  INSERT INTO public.user_stats_monthly (
    user_id, month_start, total_minutes, total_ms, total_plays,
    top_artists, top_tracks, top_albums, top_genres, hour_histogram
  )
  SELECT
    base.user_id,
    base.month_start::date,
    (base.total_ms / 60000)::integer,
    base.total_ms,
    base.total_plays,
    COALESCE(artists.j, '[]'::jsonb),
    COALESCE(tracks.j, '[]'::jsonb),
    COALESCE(albums.j, '[]'::jsonb),
    COALESCE(genres.j, '[]'::jsonb),
    COALESCE(hours.j, '[]'::jsonb)
  FROM (
    SELECT
      user_id,
      date_trunc('month', listened_at) AS month_start,
      SUM(COALESCE(duration_listened_ms, 0))::bigint AS total_ms,
      COUNT(*)::int AS total_plays
    FROM public.listening_history
    -- Las filas de un mes completo están todas en `>= month_start >= corte`:
    -- este filtro no le quita nada a esos meses y deja fuera el resto.
    WHERE listened_at >= v_cutoff
    GROUP BY user_id, date_trunc('month', listened_at)
    -- Solo meses que la poda todavía no ha tocado.
    HAVING date_trunc('month', listened_at) >= v_cutoff
  ) base
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object('id', id, 'ms', ms, 'plays', plays) ORDER BY ms DESC) AS j
    FROM (
      SELECT artist_id AS id, SUM(COALESCE(duration_listened_ms, 0))::bigint AS ms, COUNT(*)::int AS plays
      FROM public.listening_history
      WHERE user_id = base.user_id
        AND date_trunc('month', listened_at) = base.month_start
        AND artist_id IS NOT NULL AND artist_id > 0
      GROUP BY artist_id ORDER BY ms DESC LIMIT 30
    ) s
  ) artists ON true
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object('id', id, 'ms', ms, 'plays', plays)
                     ORDER BY plays DESC, ms DESC) AS j
    FROM (
      SELECT track_id AS id, SUM(COALESCE(duration_listened_ms, 0))::bigint AS ms, COUNT(*)::int AS plays
      FROM public.listening_history
      WHERE user_id = base.user_id
        AND date_trunc('month', listened_at) = base.month_start
        AND track_id IS NOT NULL AND track_id > 0
      GROUP BY track_id ORDER BY plays DESC, ms DESC LIMIT 30
    ) t
  ) tracks ON true
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object('id', id, 'ms', ms, 'plays', plays) ORDER BY ms DESC) AS j
    FROM (
      SELECT album_id AS id, SUM(COALESCE(duration_listened_ms, 0))::bigint AS ms, COUNT(*)::int AS plays
      FROM public.listening_history
      WHERE user_id = base.user_id
        AND date_trunc('month', listened_at) = base.month_start
        AND album_id IS NOT NULL AND album_id > 0
      GROUP BY album_id ORDER BY ms DESC LIMIT 20
    ) s
  ) albums ON true
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object('genre', genre, 'ms', ms, 'plays', plays) ORDER BY ms DESC) AS j
    FROM (
      SELECT genre, SUM(COALESCE(duration_listened_ms, 0))::bigint AS ms, COUNT(*)::int AS plays
      FROM public.listening_history
      WHERE user_id = base.user_id
        AND date_trunc('month', listened_at) = base.month_start
        AND genre IS NOT NULL AND genre <> ''
      GROUP BY genre ORDER BY ms DESC LIMIT 20
    ) s
  ) genres ON true
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object('dow', dow, 'hour', hour, 'ms', ms)) AS j
    FROM (
      SELECT
        EXTRACT(dow FROM listened_at)::int AS dow,
        EXTRACT(hour FROM listened_at)::int AS hour,
        SUM(COALESCE(duration_listened_ms, 0))::bigint AS ms
      FROM public.listening_history
      WHERE user_id = base.user_id
        AND date_trunc('month', listened_at) = base.month_start
      GROUP BY 1, 2
    ) s
  ) hours ON true
  ON CONFLICT (user_id, month_start) DO UPDATE SET
    total_minutes = EXCLUDED.total_minutes,
    total_ms = EXCLUDED.total_ms,
    total_plays = EXCLUDED.total_plays,
    top_artists = EXCLUDED.top_artists,
    top_tracks = EXCLUDED.top_tracks,
    top_albums = EXCLUDED.top_albums,
    top_genres = EXCLUDED.top_genres,
    hour_histogram = EXCLUDED.hour_histogram;

  DELETE FROM public.listening_history WHERE listened_at < v_cutoff;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.aggregate_monthly_listening_stats FROM authenticated, anon, public;
