import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'syncora_database.dart';
import 'daos/playlist_dao.dart';
import 'daos/saved_album_dao.dart';
import 'daos/listening_history_dao.dart';

final syncoraDatabaseProvider = Provider<SyncoraDatabase>((ref) {
  final db = SyncoraDatabase();
  ref.onDispose(() => db.close());
  return db;
});

final playlistDaoProvider = Provider<PlaylistDao>((ref) {
  return ref.watch(syncoraDatabaseProvider).playlistDao;
});

final savedAlbumDaoProvider = Provider<SavedAlbumDao>((ref) {
  return ref.watch(syncoraDatabaseProvider).savedAlbumDao;
});

final listeningHistoryDaoProvider = Provider<ListeningHistoryDao>((ref) {
  return ref.watch(syncoraDatabaseProvider).listeningHistoryDao;
});
