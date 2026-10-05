import 'package:drift/drift.dart';
import '../syncora_database.dart';

part 'folder_dao.g.dart';

/// Carpetas de playlists en Drift (Fase 8.E).
///
/// Ojo con el Pitfall #28: con cuenta, escribir solo aquí hace que el sync lo
/// revierta. Las pantallas no llaman a este DAO directo: pasan por
/// `FolderService`, que escribe en Supabase y en Drift.
@DriftAccessor(tables: [Folders, Playlists])
class FolderDao extends DatabaseAccessor<SyncoraDatabase> with _$FolderDaoMixin {
  FolderDao(super.db);

  Stream<List<Folder>> watchFolders() => (select(folders)
        ..orderBy([
          (f) => OrderingTerm(expression: f.orderIndex),
          (f) => OrderingTerm(expression: f.name.lower()),
        ]))
      .watch();

  Future<List<Folder>> getAllFolders() => select(folders).get();

  Future<Folder?> getFolderById(int id) =>
      (select(folders)..where((f) => f.id.equals(id))).getSingleOrNull();

  Future<Folder?> getFolderByRemoteId(String remoteId) =>
      (select(folders)..where((f) => f.remoteId.equals(remoteId))).getSingleOrNull();

  Future<int> createFolder({required String name, String? remoteId}) =>
      into(folders).insert(FoldersCompanion.insert(name: name, remoteId: Value(remoteId)));

  Future<void> renameFolder(int id, String name) =>
      (update(folders)..where((f) => f.id.equals(id))).write(FoldersCompanion(name: Value(name)));

  Future<void> setRemoteId(int id, String remoteId) =>
      (update(folders)..where((f) => f.id.equals(id))).write(FoldersCompanion(remoteId: Value(remoteId)));

  /// Borra la carpeta y devuelve sus playlists a la raíz (nunca las borra).
  Future<void> deleteFolder(int id) => transaction(() async {
        await (update(playlists)..where((p) => p.folderId.equals(id)))
            .write(const PlaylistsCompanion(folderId: Value(null)));
        await (delete(folders)..where((f) => f.id.equals(id))).go();
      });

  /// Solo para borrar la biblioteca local entera (`wipeLocalLibrary`): las
  /// playlists que colgaban de estas carpetas se borran ahí mismo.
  Future<int> deleteAll() => delete(folders).go();

  Future<void> setPlaylistFolder(int playlistId, int? folderId) =>
      (update(playlists)..where((p) => p.id.equals(playlistId)))
          .write(PlaylistsCompanion(folderId: Value(folderId)));
}
