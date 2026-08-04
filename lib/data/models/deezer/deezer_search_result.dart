import 'deezer_album.dart';
import 'deezer_artist.dart';
import 'deezer_track.dart';

class DeezerSearchResult {
  final List<DeezerTrack> tracks;
  final List<DeezerArtist> artists;
  final List<DeezerAlbum> albums;

  const DeezerSearchResult({
    this.tracks = const [],
    this.artists = const [],
    this.albums = const [],
  });

  bool get isEmpty => tracks.isEmpty && artists.isEmpty && albums.isEmpty;
}
