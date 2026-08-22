-- Fase 7.G: agregados mensuales de escucha (D-17 a D-19).
--
-- Sobrevive más allá de los 90 días de retención de `listening_history`
-- crudo, para poder calcular las vistas Anual y Desde-el-inicio sin
-- necesidad de guardar el historial crudo indefinidamente. `top_artists`/
-- `top_tracks` guardan solo `{id, minutos}` (top 50) -- no nombres ni
-- portadas, eso se resuelve con el caché de metadata de Deezer que ya
-- existe -- lo que mantiene cada fila en ~4 KB (ver estimación de
-- escalabilidad en docs/plan_fase_7.md).
CREATE TABLE public.user_stats_monthly (
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  month_start DATE NOT NULL,
  total_minutes INTEGER NOT NULL DEFAULT 0,
  top_artists JSONB NOT NULL DEFAULT '[]'::jsonb,
  top_tracks JSONB NOT NULL DEFAULT '[]'::jsonb,
  top_genres JSONB NOT NULL DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, month_start)
);

ALTER TABLE public.user_stats_monthly ENABLE ROW LEVEL SECURITY;

CREATE POLICY "user_stats_monthly_select_own" ON public.user_stats_monthly
  FOR SELECT USING (auth.uid() = user_id);

-- Sin política de INSERT/UPDATE/DELETE para authenticated a propósito: solo
-- escribe la función SECURITY DEFINER del cron de abajo.

-- Agrega el mes calendario recién cerrado (el anterior al mes actual, en
-- UTC) a `user_stats_monthly` para todos los usuarios con historial en ese
-- rango, y recién DESPUÉS poda `listening_history` a >90 días -- el orden
-- importa (D-19/7.G.2): nunca podar antes de agregar, o se pierde para
-- siempre el mes que todavía no se agregó.
CREATE OR REPLACE FUNCTION public.aggregate_monthly_listening_stats()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  range_start TIMESTAMPTZ := date_trunc('month', now() - interval '1 month');
  range_end TIMESTAMPTZ := date_trunc('month', now());
BEGIN
  INSERT INTO public.user_stats_monthly (user_id, month_start, total_minutes, top_artists, top_tracks, top_genres)
  SELECT
    base.user_id,
    range_start::date,
    base.total_minutes,
    COALESCE(artists.top_artists, '[]'::jsonb),
    COALESCE(tracks.top_tracks, '[]'::jsonb),
    COALESCE(genres.top_genres, '[]'::jsonb)
  FROM (
    SELECT user_id, (SUM(duration_listened_ms) / 60000)::integer AS total_minutes
    FROM public.listening_history
    WHERE listened_at >= range_start AND listened_at < range_end
    GROUP BY user_id
  ) base
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object('id', a.artist_id, 'minutes', a.minutes) ORDER BY a.minutes DESC) AS top_artists
    FROM (
      SELECT artist_id, (SUM(duration_listened_ms) / 60000)::integer AS minutes
      FROM public.listening_history
      WHERE user_id = base.user_id AND listened_at >= range_start AND listened_at < range_end AND artist_id IS NOT NULL
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
      WHERE user_id = base.user_id AND listened_at >= range_start AND listened_at < range_end AND track_id IS NOT NULL
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
      WHERE user_id = base.user_id AND listened_at >= range_start AND listened_at < range_end AND genre IS NOT NULL
      GROUP BY genre
      ORDER BY minutes DESC
    ) g
  ) genres ON true
  ON CONFLICT (user_id, month_start) DO UPDATE SET
    total_minutes = EXCLUDED.total_minutes,
    top_artists = EXCLUDED.top_artists,
    top_tracks = EXCLUDED.top_tracks,
    top_genres = EXCLUDED.top_genres;

  -- Recién ahora, con el mes ya agregado arriba, se poda el historial crudo
  -- a más de 90 días de antigüedad (retención de `listening_history`).
  DELETE FROM public.listening_history WHERE listened_at < now() - interval '90 days';
END;
$$;

-- Ejecutable solo por el rol que corre el cron (normalmente `postgres`) --
-- mismo patrón que `before_user_created_account_limit` en 7.H: sin GRANT a
-- `authenticated`, esta función nunca debe poder invocarse desde el cliente.
REVOKE EXECUTE ON FUNCTION public.aggregate_monthly_listening_stats FROM authenticated, anon, public;

-- NOTA -- 7.G.2: programar el cron es configuración de PROYECTO (requiere
-- habilitar la extensión `pg_cron` desde el Dashboard de Supabase ->
-- Database -> Extensions), no viaja en las migraciones -- mismo motivo que
-- el hook de 7.H. Una vez habilitada la extensión, correr manualmente en el
-- SQL Editor (documentado también en docs/fases/fase_7_g.md):
--
--   SELECT cron.schedule(
--     'aggregate-monthly-stats',
--     '0 5 1 * *',
--     'SELECT public.aggregate_monthly_listening_stats()'
--   );
