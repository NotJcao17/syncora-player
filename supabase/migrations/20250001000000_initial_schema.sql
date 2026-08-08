CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  avatar_seed TEXT,
  download_wifi_only BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.playlists (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  cover_url TEXT,
  is_public BOOLEAN DEFAULT false,
  is_liked BOOLEAN DEFAULT false,
  is_pinned BOOLEAN DEFAULT false,
  order_index INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.playlist_tracks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  playlist_id UUID NOT NULL REFERENCES public.playlists(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  is_public BOOLEAN DEFAULT false,
  track_id BIGINT NOT NULL,
  artist_id BIGINT,
  album_id BIGINT,
  title TEXT NOT NULL,
  artist_name TEXT NOT NULL,
  album_name TEXT,
  cover_url TEXT,
  duration_ms INTEGER,
  genre TEXT,
  order_index INTEGER DEFAULT 0,
  added_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE public.saved_albums (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  album_id BIGINT NOT NULL,
  title TEXT NOT NULL,
  artist_name TEXT NOT NULL,
  cover_url TEXT,
  added_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, album_id)
);

CREATE TABLE public.listening_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  track_id BIGINT NOT NULL,
  artist_id BIGINT,
  album_id BIGINT,
  genre TEXT,
  listened_at TIMESTAMPTZ DEFAULT NOW(),
  duration_listened_ms INTEGER
);

CREATE TABLE public.yt_matches (
  track_id BIGINT PRIMARY KEY,
  youtube_video_id TEXT NOT NULL,
  corrected_at TIMESTAMPTZ DEFAULT NOW()
);
