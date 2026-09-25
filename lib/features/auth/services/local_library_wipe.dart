import 'package:drift/drift.dart' show Value;

import '../../../data/local_db/daos/listening_history_dao.dart';
import '../../../data/local_db/daos/playlist_dao.dart';
import '../../../data/local_db/daos/saved_album_dao.dart';

/// Borra la biblioteca local (playlists con sus pistas, álbumes guardados e
/// historial). "Tus me gusta" se conserva vacía y sin `remoteId`: la app
/// siempre espera que exista.
///
/// Las descargas NO se tocan: son del dispositivo, no de ninguna cuenta, y
/// borrarlas destruiría archivos de audio que el usuario no pidió borrar.
///
/// Las pistas se borran a mano incluso en las playlists que se eliminan
/// enteras: el `ON DELETE CASCADE` de `PlaylistTracks` no se aplica en
/// runtime porque la base nunca activa `PRAGMA foreign_keys`.
///
/// Compartido por "descartar lo local" al iniciar sesión desde el modo local
/// y por "eliminar cuenta" (ronda 4).
Future<void> wipeLocalLibrary({
  required PlaylistDao dao,
  required SavedAlbumDao savedAlbumDao,
  required ListeningHistoryDao historyDao,
}) async {
  final playlists = await dao.getAllPlaylists();
  for (final playlist in playlists) {
    final tracks = await dao.getTracksOrdered(playlist.id);
    for (final track in tracks) {
      await dao.removeTrackEntry(track.id);
    }
    if (playlist.isLiked) {
      if (playlist.remoteId != null) {
        await dao.updatePlaylist(playlist.copyWith(remoteId: const Value(null)));
      }
    } else {
      await dao.deletePlaylist(playlist.id);
    }
  }

  final albums = await savedAlbumDao.getAllSavedAlbums();
  for (final album in albums) {
    await savedAlbumDao.removeSavedAlbum(album.albumId);
  }

  await historyDao.deleteAll();
}
