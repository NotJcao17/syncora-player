-- Fase 7.G, corrección post-cierre: `aggregate_monthly_listening_stats()`
-- (migración 20250001000010) solo agregaba "el mes inmediatamente anterior a
-- ahora", nunca "todos los meses cerrados que todavía no se agregaron". Si el
-- cron llegara a saltarse varios meses seguidos (pg_cron deshabilitado por
-- error, proyecto pausado, etc.), esos meses intermedios nunca se agregarían
-- -- se podarían de `listening_history` a los 90 días sin haber quedado
-- guardados nunca en `user_stats_monthly`.
--
-- Fix: en vez de un rango fijo de "mes pasado", se agrupa directamente por
-- CUALQUIER mes calendario ya cerrado (`listened_at < mes en curso`) que
-- todavía tenga filas crudas -- sin importar cuántos meses atrás. Reprocesar
-- un mes ya agregado es inofensivo (mismo `ON CONFLICT ... DO UPDATE` de
-- antes, con los mismos números), así que no hace falta distinguir "nuevo"
-- de "ya agregado". El orden agregar-antes-de-podar (D-19/7.G.2) se mantiene
-- igual.
CREATE OR REPLACE FUNCTION public.aggregate_monthly_listening_stats()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_month_start TIMESTAMPTZ := date_trunc('month', now());
BEGIN
  INSERT INTO public.user_stats_monthly (user_id, month_start, total_minutes, top_artists, top_tracks, top_genres)
  SELECT
    base.user_id,
    base.month_start::date,
    base.total_minutes,
    COALESCE(artists.top_artists, '[]'::jsonb),
    COALESCE(tracks.top_tracks, '[]'::jsonb),
    COALESCE(genres.top_genres, '[]'::jsonb)
  FROM (
    SELECT
      user_id,
      date_trunc('month', listened_at) AS month_start,
      (SUM(duration_listened_ms) / 60000)::integer AS total_minutes
    FROM public.listening_history
    WHERE listened_at < current_month_start
    GROUP BY user_id, date_trunc('month', listened_at)
  ) base
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object('id', a.artist_id, 'minutes', a.minutes) ORDER BY a.minutes DESC) AS top_artists
    FROM (
      SELECT artist_id, (SUM(duration_listened_ms) / 60000)::integer AS minutes
      FROM public.listening_history
      WHERE user_id = base.user_id
        AND date_trunc('month', listened_at) = base.month_start
        AND artist_id IS NOT NULL
      GROUP BY artist_id
      ORDER BY minutes DESC
      LIMIT 50
    ) a
  ) artists ON true
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object('id', t.track_id, 'minutes', t.minutes) ORDER BY t.minutes DESC) AS top_tracks
    FROM (
      SELECT track_id, (SUM(duration_listened_ms) / 60000)::integer AS minutes
      FROM public.listening_history
      WHERE user_id = base.user_id
        AND date_trunc('month', listened_at) = base.month_start
        AND track_id IS NOT NULL
      GROUP BY track_id
      ORDER BY minutes DESC
      LIMIT 50
    ) t
  ) tracks ON true
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object('genre', g.genre, 'minutes', g.minutes) ORDER BY g.minutes DESC) AS top_genres
    FROM (
      SELECT genre, (SUM(duration_listened_ms) / 60000)::integer AS minutes
      FROM public.listening_history
      WHERE user_id = base.user_id
        AND date_trunc('month', listened_at) = base.month_start
        AND genre IS NOT NULL
      GROUP BY genre
      ORDER BY minutes DESC
    ) g
  ) genres ON true
  ON CONFLICT (user_id, month_start) DO UPDATE SET
    total_minutes = EXCLUDED.total_minutes,
    top_artists = EXCLUDED.top_artists,
    top_tracks = EXCLUDED.top_tracks,
    top_genres = EXCLUDED.top_genres;

  -- Recién ahora, con todos los meses cerrados pendientes ya agregados
  -- arriba, se poda el historial crudo a más de 90 días de antigüedad.
  DELETE FROM public.listening_history WHERE listened_at < now() - interval '90 days';
END;
$$;

REVOKE EXECUTE ON FUNCTION public.aggregate_monthly_listening_stats FROM authenticated, anon, public;
