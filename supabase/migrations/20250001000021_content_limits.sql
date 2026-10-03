-- Ronda 5: límites de contenido como respaldo de los que ya aplica la app
-- (lib/core/limits/app_limits.dart).
--
-- - Canciones por playlist: 10 000 (igual que en la app). Una fila de
--   playlist_tracks pesa ~400 bytes: 10 000 son ~4 MB, varias veces lo que
--   pesa un usuario típico entero (Documento Maestro §4.2).
-- - Texto: la app corta en 100 (nombre) y 300 (descripción); aquí el tope es
--   más holgado (200 / 1000) para no romper filas que ya existan. NOT VALID:
--   no se revisan las filas actuales, solo las que se inserten o actualicen.

ALTER TABLE public.playlists
  ADD CONSTRAINT playlists_title_length CHECK (char_length(title) <= 200) NOT VALID;

ALTER TABLE public.playlists
  ADD CONSTRAINT playlists_description_length
  CHECK (description IS NULL OR char_length(description) <= 1000) NOT VALID;

CREATE OR REPLACE FUNCTION public.enforce_playlist_track_limit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  -- El texto 'playlist_track_limit' es el que reconoce la app
  -- (AppLimits.isTrackLimitError) para no confundirlo con una playlist borrada.
  IF (SELECT count(*) FROM public.playlist_tracks WHERE playlist_id = NEW.playlist_id) >= 10000 THEN
    RAISE EXCEPTION 'playlist_track_limit'
      USING ERRCODE = 'check_violation',
            HINT = 'Una playlist admite como máximo 10000 canciones';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS playlist_tracks_limit ON public.playlist_tracks;
CREATE TRIGGER playlist_tracks_limit
  BEFORE INSERT ON public.playlist_tracks
  FOR EACH ROW EXECUTE FUNCTION public.enforce_playlist_track_limit();
