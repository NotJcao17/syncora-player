import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'syncora_database.dart';
import 'daos/playlist_dao.dart';
import 'daos/saved_album_dao.dart';
import 'daos/listening_history_dao.dart';
import 'daos/downloaded_track_dao.dart';
import 'daos/stats_metadata_cache_dao.dart';

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

final downloadedTrackDaoProvider = Provider<DownloadedTrackDao>((ref) {
  return ref.watch(syncoraDatabaseProvider).downloadedTrackDao;
});

final statsMetadataCacheDaoProvider = Provider<StatsMetadataCacheDao>((ref) {
  return ref.watch(syncoraDatabaseProvider).statsMetadataCacheDao;
});


/// Ids de pista en "Tus me gusta", reactivo (ronda 4). Un solo stream para
/// toda la app: cada widget se suscribe con `select` a su propia pista.
final likedTrackIdsProvider = StreamProvider<Set<int>>((ref) {
  return ref.watch(playlistDaoProvider).watchLikedTrackIds();
});

/// Ids de pista guardadas en alguna playlist del usuario o en "Tus me gusta"
/// (ronda 4): alimenta el ícono de "ya está en tu biblioteca".
final libraryTrackIdsProvider = StreamProvider<Set<int>>((ref) {
  return ref.watch(playlistDaoProvider).watchLibraryTrackIds();
});
