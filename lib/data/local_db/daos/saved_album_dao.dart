import 'package:drift/drift.dart';
import '../syncora_database.dart';

part 'saved_album_dao.g.dart';

@DriftAccessor(tables: [SavedAlbums])
class SavedAlbumDao extends DatabaseAccessor<SyncoraDatabase> with _$SavedAlbumDaoMixin {
  SavedAlbumDao(super.db);

  Future<List<SavedAlbum>> getAllSavedAlbums() => (select(savedAlbums)
        ..orderBy([(t) => OrderingTerm(expression: t.addedAt, mode: OrderingMode.desc)]))
      .get();

  Stream<List<SavedAlbum>> watchAllSavedAlbums() => (select(savedAlbums)
        ..orderBy([(t) => OrderingTerm(expression: t.addedAt, mode: OrderingMode.desc)]))
      .watch();

  /// Marca el álbum como reproducido ahora (ronda 3 bis). Dato local, no
  /// viaja al sync — ver `SavedAlbums.lastPlayedAt`. No-op si el álbum no
  /// está guardado en la biblioteca, que es exactamente lo que se quiere:
  /// solo se ordena lo que el usuario tiene guardado.
  Future<void> touchLastPlayed(int albumId) =>
      (update(savedAlbums)..where((t) => t.albumId.equals(albumId)))
          .write(SavedAlbumsCompanion(lastPlayedAt: Value(DateTime.now())));

  Future<bool> isAlbumSaved(int albumId) async {
    final entry = await (select(savedAlbums)..where((t) => t.albumId.equals(albumId))).getSingleOrNull();
    return entry != null;
  }

  Future<int> saveAlbum({
    required int albumId,
    required String title,
    required String artistName,
    required String coverUrl,
  }) =>
      into(savedAlbums).insert(
        SavedAlbumsCompanion.insert(
          albumId: albumId,
          title: title,
          artistName: artistName,
          coverUrl: coverUrl,
        ),
        mode: InsertMode.insertOrReplace,
      );

  Future<int> removeSavedAlbum(int albumId) =>
      (delete(savedAlbums)..where((t) => t.albumId.equals(albumId))).go();

  Future<bool> toggleSaveAlbum({
    required int albumId,
    required String title,
    required String artistName,
    required String coverUrl,
  }) async {
    return transaction(() async {
      final saved = await isAlbumSaved(albumId);
      if (saved) {
        await removeSavedAlbum(albumId);
        return false;
      } else {
        await saveAlbum(
          albumId: albumId,
          title: title,
          artistName: artistName,
          coverUrl: coverUrl,
        );
        return true;
      }
    });
  }
}
