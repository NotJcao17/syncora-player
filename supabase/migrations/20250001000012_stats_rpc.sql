-- Rediseño de Estadísticas -- lectura agregada en el servidor (H-S5, H-S7,
-- H-S10, H-S11) y agregado mensual ampliado.
--
-- POR QUÉ UN RPC Y NO BAJAR LAS FILAS
-- El cliente pedía `listening_history` fila a fila y sumaba en Dart. Dos
-- problemas: PostgREST aplica su `max-rows` (1000 por defecto) y la consulta
-- no pedía `limit` ni `order`, así que una ventana de 30 días de uso intenso
-- devolvía un subconjunto ARBITRARIO sin avisar; y en egress una vista de 30
-- días son ~200 KB por carga (~5 KB agregando aquí). Con 250 usuarios en el
-- plan free eso es la diferencia entre >1 GB/mes y ~30 MB/mes. Serializar
-- 3000 filas a JSON tampoco es más barato en CPU que agruparlas.
--
-- TODO EN MILISEGUNDOS
-- Se devuelven ms crudos, nunca minutos. El cálculo en Dart hacía `ceil()`
-- por cada artista y cada canción mientras el SQL hacía división entera:
-- la suma de los minutos por artista no daba el total, y el mismo mes
-- cambiaba de número al pasar de "crudo" a "agregado" (H-S7). Ahora se
-- redondea una sola vez, al pintar.

-- ---------------------------------------------------------------------
-- 1) Índice para las consultas por ventana de fechas.
--    Solo existía `(user_id)`. El índice único de dedupe es
--    `(user_id, track_id, listened_at)`, que no sirve para filtrar por rango
--    de fechas sin conocer track_id.
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_listening_history_user_listened_at
  ON public.listening_history (user_id, listened_at DESC);

-- ---------------------------------------------------------------------
-- 2) `user_stats_monthly` gana lo que faltaba para las vistas largas.
--    Sin `plays` no hay "top canciones con nº de reproducciones" fuera de
--    los 90 días de historial crudo (H-S10); sin el histograma no hay mapa
--    de hábitos; y `total_minutes` arrastra el redondeo inconsistente.
-- ---------------------------------------------------------------------
ALTER TABLE public.user_stats_monthly
  ADD COLUMN IF NOT EXISTS total_ms BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_plays INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS top_albums JSONB NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS hour_histogram JSONB NOT NULL DEFAULT '[]'::jsonb;

-- ---------------------------------------------------------------------
-- 3) El RPC de lectura.
--
--    SECURITY INVOKER a propósito: corre con los permisos de quien llama, así
--    que la política RLS `listening_history_own` sigue aplicando y un usuario
--    no puede leer las escuchas de otro ni pasando otro rango. Se filtra
--    además explícitamente por `auth.uid()` para que el índice se use.
--
--    `p_tz_offset_minutes`: los cortes por día/semana/mes tienen que caer en
--    la medianoche LOCAL del usuario, no en UTC, o la gráfica de "últimos 7
--    días" sale corrida. Se pasa el desfase en minutos en vez de un nombre de
--    zona IANA porque es lo que Dart sabe dar sin dependencias.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_listening_stats(
  p_from TIMESTAMPTZ,
  p_to TIMESTAMPTZ,
  p_bucket TEXT DEFAULT 'day',
  p_top INTEGER DEFAULT 25,
  p_tz_offset_minutes INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  uid UUID := auth.uid();
  tz INTERVAL := make_interval(mins => COALESCE(p_tz_offset_minutes, 0));
  bucket TEXT := CASE WHEN p_bucket IN ('day', 'week', 'month') THEN p_bucket ELSE 'day' END;
  top_n INTEGER := LEAST(GREATEST(COALESCE(p_top, 25), 1), 100);
  result JSONB;
BEGIN
  IF uid IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;

  WITH scoped AS (
    SELECT
      track_id,
      artist_id,
      album_id,
      genre,
      COALESCE(duration_listened_ms, 0) AS ms,
      listened_at + tz AS local_at
    FROM public.listening_history
    WHERE user_id = uid
      AND listened_at >= p_from
      AND listened_at < p_to
  ),
  totals AS (
    SELECT
      COALESCE(SUM(ms), 0)::bigint AS total_ms,
      COUNT(*)::int AS total_plays,
      COUNT(DISTINCT artist_id) FILTER (WHERE artist_id > 0)::int AS distinct_artists,
      COUNT(DISTINCT track_id) FILTER (WHERE track_id > 0)::int AS distinct_tracks,
      COUNT(DISTINCT album_id) FILTER (WHERE album_id > 0)::int AS distinct_albums,
      COUNT(DISTINCT date_trunc('day', local_at))::int AS active_days
    FROM scoped
  ),
  top_artists AS (
    SELECT jsonb_agg(jsonb_build_object('id', id, 'ms', ms, 'plays', plays) ORDER BY ms DESC) AS j
    FROM (
      SELECT artist_id AS id, SUM(ms)::bigint AS ms, COUNT(*)::int AS plays
      FROM scoped WHERE artist_id > 0
      GROUP BY artist_id ORDER BY ms DESC LIMIT top_n
    ) s
  ),
  top_tracks AS (
    SELECT jsonb_agg(jsonb_build_object('id', id, 'ms', ms, 'plays', plays) ORDER BY ms DESC) AS j
    FROM (
      SELECT track_id AS id, SUM(ms)::bigint AS ms, COUNT(*)::int AS plays
      FROM scoped WHERE track_id > 0
      GROUP BY track_id ORDER BY ms DESC LIMIT top_n
    ) s
  ),
  top_albums AS (
    SELECT jsonb_agg(jsonb_build_object('id', id, 'ms', ms, 'plays', plays) ORDER BY ms DESC) AS j
    FROM (
      SELECT album_id AS id, SUM(ms)::bigint AS ms, COUNT(*)::int AS plays
      FROM scoped WHERE album_id > 0
      GROUP BY album_id ORDER BY ms DESC LIMIT top_n
    ) s
  ),
  top_genres AS (
    SELECT jsonb_agg(jsonb_build_object('genre', genre, 'ms', ms, 'plays', plays) ORDER BY ms DESC) AS j
    FROM (
      SELECT genre, SUM(ms)::bigint AS ms, COUNT(*)::int AS plays
      FROM scoped WHERE genre IS NOT NULL AND genre <> ''
      GROUP BY genre ORDER BY ms DESC LIMIT top_n
    ) s
  ),
  series AS (
    SELECT jsonb_agg(jsonb_build_object('t', b, 'ms', ms, 'plays', plays) ORDER BY b) AS j
    FROM (
      SELECT date_trunc(bucket, local_at) AS b, SUM(ms)::bigint AS ms, COUNT(*)::int AS plays
      FROM scoped
      GROUP BY 1
    ) s
  ),
  hours AS (
    SELECT jsonb_agg(jsonb_build_object('dow', dow, 'hour', hour, 'ms', ms)) AS j
    FROM (
      SELECT
        EXTRACT(dow FROM local_at)::int AS dow,
        EXTRACT(hour FROM local_at)::int AS hour,
        SUM(ms)::bigint AS ms
      FROM scoped
      GROUP BY 1, 2
    ) s
  )
  SELECT jsonb_build_object(
    'total_ms', totals.total_ms,
    'total_plays', totals.total_plays,
    'distinct_artists', totals.distinct_artists,
    'distinct_tracks', totals.distinct_tracks,
    'distinct_albums', totals.distinct_albums,
    'active_days', totals.active_days,
    'top_artists', COALESCE(top_artists.j, '[]'::jsonb),
    'top_tracks', COALESCE(top_tracks.j, '[]'::jsonb),
    'top_albums', COALESCE(top_albums.j, '[]'::jsonb),
    'top_genres', COALESCE(top_genres.j, '[]'::jsonb),
    'series', COALESCE(series.j, '[]'::jsonb),
    'hours', COALESCE(hours.j, '[]'::jsonb)
  )
  INTO result
  FROM totals, top_artists, top_tracks, top_albums, top_genres, series, hours;

  RETURN COALESCE(result, '{}'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_listening_stats(
  TIMESTAMPTZ, TIMESTAMPTZ, TEXT, INTEGER, INTEGER
) TO authenticated;

-- ---------------------------------------------------------------------
-- 4) Agregado mensual: ahora incluye el MES EN CURSO.
--
--    Antes solo agregaba meses ya cerrados, así que las vistas largas (6/12
--    meses, "Desde el inicio"), que se arman con `user_stats_monthly`, nunca
--    veían lo escuchado este mes. Reprocesar un mes es idempotente (mismo
--    `ON CONFLICT DO UPDATE` con los mismos números), así que se recalcula el
--    mes actual en cada corrida y el cron pasa a ser diario.
--
--    Se mantiene el orden agregar-antes-de-podar (D-19/7.G.2) y la retención
--    de 90 días del historial crudo: es lo que permite quedarse en el plan
--    free. Los tops de los periodos largos son por eso aproximados (se
--    guardan 30 por mes, un artista que queda #35 todos los meses no sale),
--    pero los TOTALES de ms y reproducciones son exactos.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.aggregate_monthly_listening_stats()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
    GROUP BY user_id, date_trunc('month', listened_at)
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
    SELECT jsonb_agg(jsonb_build_object('id', id, 'ms', ms, 'plays', plays) ORDER BY ms DESC) AS j
    FROM (
      SELECT track_id AS id, SUM(COALESCE(duration_listened_ms, 0))::bigint AS ms, COUNT(*)::int AS plays
      FROM public.listening_history
      WHERE user_id = base.user_id
        AND date_trunc('month', listened_at) = base.month_start
        AND track_id IS NOT NULL AND track_id > 0
      GROUP BY track_id ORDER BY ms DESC LIMIT 30
    ) s
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

  -- Recién ahora, con todo lo pendiente ya agregado, se poda el crudo.
  DELETE FROM public.listening_history WHERE listened_at < now() - interval '90 days';
END;
$$;

REVOKE EXECUTE ON FUNCTION public.aggregate_monthly_listening_stats FROM authenticated, anon, public;
