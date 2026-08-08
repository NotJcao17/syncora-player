-- Indexes for lightning fast queries on foreign keys and RLS filters
CREATE INDEX IF NOT EXISTS idx_playlists_user_id ON public.playlists(user_id);
CREATE INDEX IF NOT EXISTS idx_playlist_tracks_playlist_id ON public.playlist_tracks(playlist_id);
CREATE INDEX IF NOT EXISTS idx_playlist_tracks_user_id ON public.playlist_tracks(user_id);
CREATE INDEX IF NOT EXISTS idx_saved_albums_user_id ON public.saved_albums(user_id);
CREATE INDEX IF NOT EXISTS idx_listening_history_user_id ON public.listening_history(user_id);
