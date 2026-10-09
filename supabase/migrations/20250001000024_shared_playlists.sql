-- Playlists compartidas (2026-10-09).
--
-- 1. Agujero de RLS en `playlist_tracks`.
--
--    La política original (`auth.uid() = user_id`, migración 2) solo exigía que
--    la fila llevara el id de quien la escribe, no que la playlist fuera suya.
--    Mientras nadie conocía ids ajenos daba igual; con los enlaces compartidos
--    (`syncoraplayer.app/playlist/<id>`) el id es público, y cualquiera con
--    sesión podía insertar canciones en la playlist de otro por la API REST.
--    Peor: el dueño no podía quitarlas, porque el DELETE también filtraba por
--    `user_id` y la fila era del intruso.
--
--    Ahora escribir exige que la playlist sea tuya, y el dueño de la playlist
--    puede leer y borrar cualquier fila de ella (para limpiar si algo se coló
--    antes de este arreglo). La lectura pública sigue en
--    `playlist_tracks_public_read`.
--
-- 2. `followed_playlists`: una playlist compartida que otro usuario guardó en
--    su biblioteca. No copia nada: la app lee la playlist original (pública por
--    RLS) y la guarda en local como solo lectura. Si el dueño la borra, la fila
--    se va en cascada; si la hace privada, la fila se queda pero ya no se puede
--    leer, y vuelve sola si la comparte otra vez.

-- 1 ---------------------------------------------------------------------------

-- Filas que alguien haya podido colar en playlists ajenas antes del arreglo.
DELETE FROM public.playlist_tracks pt
USING public.playlists p
WHERE p.id = pt.playlist_id
  AND p.user_id <> pt.user_id;

DROP POLICY IF EXISTS "playlist_tracks_owner" ON public.playlist_tracks;

CREATE POLICY "playlist_tracks_owner" ON public.playlist_tracks
  FOR ALL
  USING (
    (SELECT auth.uid()) = user_id
    OR EXISTS (
      SELECT 1 FROM public.playlists p
      WHERE p.id = playlist_id AND p.user_id = (SELECT auth.uid())
    )
  )
  WITH CHECK (
    (SELECT auth.uid()) = user_id
    AND EXISTS (
      SELECT 1 FROM public.playlists p
      WHERE p.id = playlist_id AND p.user_id = (SELECT auth.uid())
    )
  );

-- 2 ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.followed_playlists (
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  playlist_id UUID NOT NULL REFERENCES public.playlists(id) ON DELETE CASCADE,
  followed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, playlist_id)
);

CREATE INDEX IF NOT EXISTS followed_playlists_playlist_id_idx
  ON public.followed_playlists(playlist_id);

ALTER TABLE public.followed_playlists ENABLE ROW LEVEL SECURITY;

CREATE POLICY "followed_playlists_select_own" ON public.followed_playlists
  FOR SELECT USING ((SELECT auth.uid()) = user_id);

-- Solo playlists públicas y ajenas: guardar una propia no tiene sentido y
-- guardar una privada sería una forma de enterarse de que existe.
CREATE POLICY "followed_playlists_insert_own" ON public.followed_playlists
  FOR INSERT WITH CHECK (
    (SELECT auth.uid()) = user_id
    AND EXISTS (
      SELECT 1 FROM public.playlists p
      WHERE p.id = playlist_id
        AND p.is_public = true
        AND p.user_id <> (SELECT auth.uid())
    )
  );

CREATE POLICY "followed_playlists_delete_own" ON public.followed_playlists
  FOR DELETE USING ((SELECT auth.uid()) = user_id);

-- Tope de respaldo, como los de la migración 21. Una fila pesa unos 60 bytes;
-- el límite es para que nadie llene la tabla a propósito, no por espacio.
CREATE OR REPLACE FUNCTION public.enforce_followed_playlist_limit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  -- El texto 'followed_playlist_limit' es el que reconoce la app.
  IF (SELECT count(*) FROM public.followed_playlists WHERE user_id = NEW.user_id) >= 500 THEN
    RAISE EXCEPTION 'followed_playlist_limit'
      USING ERRCODE = 'check_violation',
            HINT = 'Se pueden guardar como máximo 500 playlists de otras personas';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS followed_playlists_limit ON public.followed_playlists;
CREATE TRIGGER followed_playlists_limit
  BEFORE INSERT ON public.followed_playlists
  FOR EACH ROW EXECUTE FUNCTION public.enforce_followed_playlist_limit();
