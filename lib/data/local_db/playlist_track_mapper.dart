import '../../features/player/player_models.dart';
import 'syncora_database.dart';

/// Fila de Drift -> pista del reproductor.
///
/// Función de nivel superior a propósito: la pantalla de playlist la corre en
/// un isolate para listas grandes (ronda 5), y Android Auto la usa para
/// armar la cola de una playlist.
SyncoraTrack playlistTrackToSyncora(PlaylistTrack t) {
  var parsedArtists = SyncoraArtistRef.decodeList(t.contributorsJson);
  if (parsedArtists.isEmpty && t.artistName.contains(', ')) {
    final names = t.artistName.split(', ');
    parsedArtists = [
      for (int i = 0; i < names.length; i++) SyncoraArtistRef(id: i == 0 ? t.artistId : 0, name: names[i].trim()),
    ];
  } else if (parsedArtists.isEmpty && (t.artistId != 0 || t.artistName.isNotEmpty)) {
    parsedArtists = [SyncoraArtistRef(id: t.artistId, name: t.artistName)];
  }
  return SyncoraTrack(
    id: t.trackId.toString(),
    title: t.title,
    artist: t.artistName,
    artists: parsedArtists,
    artistId: t.artistId,
    album: t.albumName,
    albumId: t.albumId,
    duration: Duration(milliseconds: t.durationMs),
    artUri: t.coverUrl.isNotEmpty ? Uri.tryParse(t.coverUrl) : null,
  );
}

/// Pista descargada -> pista del reproductor.
SyncoraTrack downloadedTrackToSyncora(DownloadedTrack t) {
  final artists = SyncoraArtistRef.decodeList(t.contributorsJson);
  return SyncoraTrack(
    id: t.trackId.toString(),
    title: t.title,
    artist: t.artistName,
    artists: artists,
    artistId: t.artistId,
    album: t.albumName,
    albumId: t.albumId,
    duration: Duration(milliseconds: t.durationMs),
    artUri: t.coverUrl.isNotEmpty ? Uri.tryParse(t.coverUrl) : null,
  );
}
