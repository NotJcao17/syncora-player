import 'deezer_album.dart';
import 'deezer_playlist.dart';
import 'deezer_artist.dart';
import 'deezer_track.dart';

class DeezerSearchResult {
  final List<DeezerTrack> tracks;
  final List<DeezerArtist> artists;
  final List<DeezerAlbum> albums;

  /// Ronda 5: solo con el filtro "Playlists" (nunca en "Todo").
  final List<DeezerPlaylist> playlists;

  const DeezerSearchResult({
    this.tracks = const [],
    this.artists = const [],
    this.albums = const [],
    this.playlists = const [],
  });

  bool get isEmpty => tracks.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty;
}
