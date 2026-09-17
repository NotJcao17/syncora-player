import '../../../data/apis/deezer_api.dart';
import '../../../data/local_db/daos/downloaded_track_dao.dart';
import '../../../data/local_db/daos/playlist_dao.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../player/player_models.dart';

/// Reconstruye pistas reproducibles a partir de los IDs sueltos que guarda
/// `listening_history` (que solo tiene `trackId`/`artistId`/`albumId`).
///
/// Orden de resolución, de barato a caro:
///
/// 1. `playlist_tracks` — cualquier playlist local del usuario. Gratis y
///    disponible sin conexión.
/// 2. `downloaded_tracks` — descargas. Gratis y sin conexión.
/// 3. `/track/{id}` de Deezer, y solo para las que faltaron, con un tope
///    duro ([maxRemoteLookups]).
///
/// El tope existe porque "On Repeat" pide ~30 pistas: sin él, un usuario
/// nuevo que todavía no tiene nada guardado en playlists dispararía 30
/// peticiones en el arranque de Inicio. Con el tope, se resuelven las más
/// repetidas (que es el orden en que llegan) y el mix sale un poco más corto.
///
/// Se bajó de 12 a 6 tras las pruebas en dispositivo: pulsar reproducir justo
/// al abrir la app se sentía lento, y esta ráfaga era de lo poco que competía
/// con el arranque del reproductor. La mayoría de las pistas se resuelven sin
/// red de todos modos.
class TrackResolver {
  const TrackResolver({
    required this.playlistDao,
    required this.downloadedTrackDao,
    required this.deezerApi,
  });

  final PlaylistDao playlistDao;
  final DownloadedTrackDao downloadedTrackDao;
  final DeezerApi deezerApi;

  static const int maxRemoteLookups = 6;

  /// Resuelve [trackIds] respetando su orden. Las que no se pudieron resolver
  /// simplemente no aparecen en el resultado.
  Future<List<SyncoraTrack>> resolve(
    List<int> trackIds, {
    bool allowNetwork = true,
  }) async {
    if (trackIds.isEmpty) return [];

    final wanted = trackIds.toSet();
    final resolved = <int, SyncoraTrack>{};

    final fromPlaylists = await playlistDao.findTracksByIds(wanted);
    for (final entry in fromPlaylists.entries) {
      resolved[entry.key] = _fromPlaylistTrack(entry.value);
    }

    final missingAfterPlaylists = wanted.where((id) => !resolved.containsKey(id)).toSet();
    if (missingAfterPlaylists.isNotEmpty) {
      // Las descargas se leen de una y se indexan en memoria: son pocas y no
      // vale la pena una consulta por id.
      final downloads = await downloadedTrackDao.getAllDownloaded();
      for (final row in downloads) {
        if (missingAfterPlaylists.contains(row.trackId)) {
          resolved[row.trackId] = _fromDownloadedTrack(row);
        }
      }
    }

    final stillMissing = trackIds.where((id) => !resolved.containsKey(id)).toList();
    if (allowNetwork && stillMissing.isNotEmpty) {
      final toFetch = stillMissing.take(maxRemoteLookups).toList();
      await Future.wait(toFetch.map((id) async {
        try {
          final track = await deezerApi.getTrack(id);
          if (track.id > 0) resolved[id] = track.toSyncoraTrack();
        } catch (_) {
          // Sin red o pista retirada del catálogo: se omite del mix.
        }
      }));
    }

    return [
      for (final id in trackIds)
        if (resolved[id] != null) resolved[id]!,
    ];
  }

  static SyncoraTrack _fromPlaylistTrack(PlaylistTrack row) => SyncoraTrack(
        id: row.trackId.toString(),
        title: row.title,
        artist: row.artistName,
        artistId: row.artistId,
        album: row.albumName,
        albumId: row.albumId,
        duration: Duration(milliseconds: row.durationMs),
        artUri: row.coverUrl.isNotEmpty ? Uri.tryParse(row.coverUrl) : null,
        genre: row.genre,
      );

  static SyncoraTrack _fromDownloadedTrack(DownloadedTrack row) => SyncoraTrack(
        id: row.trackId.toString(),
        title: row.title,
        artist: row.artistName,
        artistId: row.artistId,
        album: row.albumName,
        albumId: row.albumId,
        duration: Duration(milliseconds: row.durationMs),
        artUri: row.coverUrl.isNotEmpty ? Uri.tryParse(row.coverUrl) : null,
      );
}
