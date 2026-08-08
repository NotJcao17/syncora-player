CREATE OR REPLACE FUNCTION sync_playlist_tracks_is_public()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE public.playlist_tracks SET is_public = NEW.is_public
  WHERE playlist_id = NEW.id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER playlist_tracks_sync_is_public
AFTER UPDATE OF is_public ON public.playlists
FOR EACH ROW EXECUTE FUNCTION sync_playlist_tracks_is_public();

CREATE OR REPLACE FUNCTION set_playlist_track_defaults()
RETURNS TRIGGER AS $$
BEGIN
  SELECT is_public INTO NEW.is_public
  FROM public.playlists WHERE id = NEW.playlist_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER playlist_track_set_defaults
BEFORE INSERT ON public.playlist_tracks
FOR EACH ROW EXECUTE FUNCTION set_playlist_track_defaults();
