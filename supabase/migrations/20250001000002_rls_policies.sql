ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.playlists ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.playlist_tracks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.saved_albums ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.listening_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.yt_matches ENABLE ROW LEVEL SECURITY;

CREATE POLICY "profiles_own" ON public.profiles FOR ALL USING (auth.uid() = id);
CREATE POLICY "playlists_owner" ON public.playlists FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "playlists_public_read" ON public.playlists FOR SELECT USING (is_public = true);
CREATE POLICY "playlist_tracks_owner" ON public.playlist_tracks FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "playlist_tracks_public_read" ON public.playlist_tracks FOR SELECT USING (is_public = true);
CREATE POLICY "saved_albums_own" ON public.saved_albums FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "listening_history_own" ON public.listening_history FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "yt_matches_read" ON public.yt_matches FOR SELECT USING (true);
CREATE POLICY "yt_matches_write" ON public.yt_matches FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);
