CREATE UNIQUE INDEX IF NOT EXISTS unique_liked_playlist_per_user ON public.playlists (user_id) WHERE (is_liked = true);

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, avatar_seed)
  VALUES (NEW.id, NEW.id::TEXT);

  INSERT INTO public.playlists (user_id, title, is_liked)
  VALUES (NEW.id, 'Tus me gusta', true)
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP POLICY IF EXISTS "Prevent delete liked playlist" ON public.playlists;
CREATE POLICY "Prevent delete liked playlist"
ON public.playlists FOR DELETE
USING (auth.uid() = user_id AND is_liked = false);
