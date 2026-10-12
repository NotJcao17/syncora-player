import 'package:drift/drift.dart';

import '../../../data/local_db/daos/folder_dao.dart';
import '../../../data/local_db/daos/listening_history_dao.dart';
import '../../../data/local_db/daos/playlist_dao.dart';
import '../../../data/local_db/daos/saved_album_dao.dart';
import '../../../data/local_db/syncora_database.dart';

/// Borra la biblioteca local (playlists con sus pistas, carpetas, álbumes
/// guardados e historial). "Tus me gusta" se conserva vacía y sin
/// `remoteId`: la app siempre espera que exista.
///
/// Las descargas NO se tocan: son del dispositivo, no de ninguna cuenta, y
/// borrarlas destruiría archivos de audio que el usuario no pidió borrar.
///
/// Las pistas se borran aparte: el `ON DELETE CASCADE` de `PlaylistTracks` no
/// se aplica en runtime porque la base nunca activa `PRAGMA foreign_keys`.
///
/// Compartido por "descartar lo local" al iniciar sesión desde el modo local,
/// por "eliminar cuenta" (ronda 4) y por el cambio de cuenta
/// (`account_data_owner.dart`).
///
/// Ronda 8 (H-R8-14): todo en **una transacción con borrados en bloque**.
/// Antes era una sentencia por canción (miles con una biblioteca importada):
/// tardaba segundos, la UI se vaciaba a la vista y otra escritura podía
/// colarse en medio. Dentro de la transacción cualquier otra escritura espera
/// a que termine.
Future<void> wipeLocalLibrary({
  required PlaylistDao dao,
  required SavedAlbumDao savedAlbumDao,
  required ListeningHistoryDao historyDao,
  required FolderDao folderDao,
}) async {
  final db = dao.attachedDatabase;
  await db.transaction(() async {
    await db.delete(db.playlistTracks).go();
    await (db.delete(db.playlists)..where((p) => p.isLiked.equals(false))).go();
    await (db.update(db.playlists)..where((p) => p.isLiked.equals(true)))
        .write(const PlaylistsCompanion(remoteId: Value(null)));
    // Las carpetas (Fase 8.E) llegaron después de esta función y se quedaban
    // vacías en la biblioteca de la siguiente cuenta.
    await db.delete(db.folders).go();
    await db.delete(db.savedAlbums).go();
    await db.delete(db.listeningHistory).go();
  });
}
