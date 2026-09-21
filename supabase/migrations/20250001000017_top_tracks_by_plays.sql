-- El top de CANCIONES se ordena por número de reproducciones, no por minutos.
--
-- Con el orden por minutos aparecían canciones con 3 reproducciones por
-- debajo de otras con 1, porque una canción larga escuchada una vez suma más
-- tiempo que una corta escuchada tres veces. Para "tus canciones" lo que la
-- gente espera es cuántas veces la puso.
--
-- Hay que cambiarlo AQUÍ y no solo al pintar: el `LIMIT` del top se aplica en
-- el servidor, así que ordenar en el cliente solo reordenaría una selección
-- que ya se hizo con el criterio equivocado — una canción muy repetida pero
-- corta podía quedarse fuera del top antes de llegar a la app.
--
-- Los minutos siguen siendo el desempate, y el top de ARTISTAS sigue por
-- tiempo: ahí "a quién escuchaste más" sí es tiempo, no número de pistas.
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
    SELECT jsonb_agg(jsonb_build_object('id', id, 'ms', ms, 'plays', plays)
                     ORDER BY plays DESC, ms DESC) AS j
    FROM (
      SELECT track_id AS id, SUM(ms)::bigint AS ms, COUNT(*)::int AS plays
      FROM scoped WHERE track_id > 0
      GROUP BY track_id ORDER BY plays DESC, ms DESC LIMIT top_n
    ) t
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

-- Mismo criterio en el agregado mensual, del que salen las ventanas largas:
-- si no, el top de canciones cambiaría de significado al pasar de 3 a 6
-- meses.
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

  DELETE FROM public.listening_history WHERE listened_at < now() - interval '90 days';
END;
$$;

REVOKE EXECUTE ON FUNCTION public.aggregate_monthly_listening_stats FROM authenticated, anon, public;
