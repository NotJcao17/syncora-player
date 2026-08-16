-- Persistir colaboradores (más de 1 artista por pista) también en Supabase.
-- Hasta ahora solo se guardaban en SQLite local (PlaylistTracks.contributorsJson,
-- Fase 0), y el payload que se sube a la nube nunca incluyó esta columna —
-- así que una playlist restaurada puramente desde Supabase (reinstalación,
-- otro dispositivo) perdía los colaboradores extra y solo conservaba el
-- artista principal (artist_name/artist_id).
--
-- Mismo formato que la columna local: JSON de List<{id, name}> con todos los
-- contributors de Deezer, o NULL si no se pudo resolver más de un artista.
ALTER TABLE public.playlist_tracks
  ADD COLUMN IF NOT EXISTS contributors_json TEXT;
