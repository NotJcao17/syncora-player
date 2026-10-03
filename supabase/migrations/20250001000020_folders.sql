-- Fase 8.E: carpetas de playlists (un solo nivel: una carpeta contiene
-- playlists, nunca otras carpetas). Documento Maestro §2.1.3 y §8.
--
-- Borrar una carpeta NUNCA borra sus playlists: `ON DELETE SET NULL` las
-- devuelve a la raíz de la biblioteca. Borrar la cuenta borra las carpetas
-- por la cascada de `auth.users` (ver `delete_my_account`).

CREATE TABLE public.folders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 100),
  order_index INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX folders_user_id_idx ON public.folders(user_id);

ALTER TABLE public.folders ENABLE ROW LEVEL SECURITY;

-- Solo el dueño. Las carpetas no se comparten: compartir sigue siendo por
-- playlist (`is_public`).
CREATE POLICY "folders_owner" ON public.folders
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

ALTER TABLE public.playlists
  ADD COLUMN folder_id UUID REFERENCES public.folders(id) ON DELETE SET NULL;

CREATE INDEX playlists_folder_id_idx ON public.playlists(folder_id);

-- Una playlist solo puede ir a una carpeta del mismo usuario. El RLS de
-- `playlists` ya impide tocar playlists ajenas, pero no impediría apuntar la
-- propia a una carpeta ajena cuyo UUID se conociera.
CREATE OR REPLACE FUNCTION public.playlists_folder_same_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.folder_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.folders f WHERE f.id = NEW.folder_id AND f.user_id = NEW.user_id
  ) THEN
    RAISE EXCEPTION 'La carpeta no pertenece al dueño de la playlist';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER playlists_folder_same_owner
  BEFORE INSERT OR UPDATE OF folder_id ON public.playlists
  FOR EACH ROW EXECUTE FUNCTION public.playlists_folder_same_owner();
