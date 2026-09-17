import 'package:drift/drift.dart';
import '../syncora_database.dart';

part 'playlist_dao.g.dart';

@DriftAccessor(tables: [Playlists, PlaylistTracks])
class PlaylistDao extends DatabaseAccessor<SyncoraDatabase> with _$PlaylistDaoMixin {
  PlaylistDao(super.db);

  // Playlists CRUD
  Future<List<Playlist>> getAllPlaylists() => (select(playlists)
        ..orderBy([
          (t) => OrderingTerm(expression: t.isPinned, mode: OrderingMode.desc),
          (t) => OrderingTerm(expression: t.orderIndex, mode: OrderingMode.asc),
          (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        ]))
      .get();

  Stream<List<Playlist>> watchAllPlaylists() => (select(playlists)
        ..orderBy([
          (t) => OrderingTerm(expression: t.isPinned, mode: OrderingMode.desc),
          (t) => OrderingTerm(expression: t.orderIndex, mode: OrderingMode.asc),
          (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
        ]))
      .watch();

  /// Marca la playlist como reproducida ahora (ronda 3, D1).
  ///
  /// Alimenta el orden "escuchadas recientemente" de Biblioteca. Es un dato
  /// local: no viaja a Supabase (ver el docstring de `Playlists.lastPlayedAt`),
  /// así que se escribe directo al DAO sin pasar por el servicio compartido —
  /// el Pitfall #28 aplica a datos que el sync poda, y este no es uno de
  /// ellos.
  Future<void> touchLastPlayed(int id) =>
      (update(playlists)..where((t) => t.id.equals(id)))
          .write(PlaylistsCompanion(lastPlayedAt: Value(DateTime.now())));

  Future<Playlist?> getPlaylistById(int id) =>
      (select(playlists)..where((t) => t.id.equals(id))).getSingleOrNull();

  Stream<Playlist?> watchPlaylistById(int id) =>
      (select(playlists)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Stream<Playlist?> watchLikedPlaylist() =>
      (select(playlists)..where((t) => t.isLiked.equals(true))).watchSingleOrNull();

  Future<Playlist?> getPlaylistByRemoteId(String remoteId) =>
      (select(playlists)..where((t) => t.remoteId.equals(remoteId))).getSingleOrNull();

  Future<Playlist> getLikedPlaylist() async {
    final existing = await (select(playlists)..where((t) => t.isLiked.equals(true))).getSingleOrNull();
    if (existing != null) return existing;

    final id = await into(playlists).insert(
      PlaylistsCompanion.insert(
        title: 'Tus me gusta',
        description: const Value('Pistas que te han gustado'),
        isLiked: const Value(true),
        isPinned: const Value(true),
        orderIndex: const Value(-1),
      ),
    );
    return (await getPlaylistById(id))!;
  }

  Future<int> createPlaylist({
    required String title,
    String? description,
    String? coverUrl,
    String? remoteId,
    bool isPublic = false,
  }) async {
    return into(playlists).insert(
      PlaylistsCompanion.insert(
        title: title,
        description: Value(description),
        coverUrl: Value(coverUrl),
        remoteId: Value(remoteId),
        isPublic: Value(isPublic),
      ),
    );
  }

  Future<bool> updatePlaylist(Playlist playlist) =>
      update(playlists).replace(playlist);

  Future<int> deletePlaylist(int id) =>
      (delete(playlists)..where((t) => t.id.equals(id))).go();

  // Tracks in Playlists
  Future<List<PlaylistTrack>> getTracksOrdered(int playlistId) =>
      (select(playlistTracks)
            ..where((t) => t.playlistId.equals(playlistId))
            ..orderBy([(t) => OrderingTerm(expression: t.orderIndex, mode: OrderingMode.asc)]))
          .get();

  Stream<List<PlaylistTrack>> watchTracksOrdered(int playlistId) =>
      (select(playlistTracks)
            ..where((t) => t.playlistId.equals(playlistId))
            ..orderBy([(t) => OrderingTerm(expression: t.orderIndex, mode: OrderingMode.asc)]))
          .watch();

  Future<int> addTrackToPlaylist({
    required int playlistId,
    required int trackId,
    required int artistId,
    required int albumId,
    required String title,
    required String artistName,
    required String albumName,
    required String coverUrl,
    required int durationMs,
    String? genre,
    String? contributorsJson,
  }) async {
    // Determine orderIndex (max + 1)
    final existingTracks = await getTracksOrdered(playlistId);
    final nextOrder = existingTracks.isEmpty ? 0 : existingTracks.map((e) => e.orderIndex).reduce((a, b) => a > b ? a : b) + 1;

    return into(playlistTracks).insert(
      PlaylistTracksCompanion.insert(
        playlistId: playlistId,
        trackId: trackId,
        artistId: artistId,
        albumId: albumId,
        title: title,
        artistName: artistName,
        albumName: albumName,
        coverUrl: coverUrl,
        durationMs: durationMs,
        genre: Value(genre),
        contributorsJson: Value(contributorsJson),
        orderIndex: Value(nextOrder),
      ),
    );
  }

  Future<int> removeTrackFromPlaylist(int playlistId, int trackId) =>
      (delete(playlistTracks)
            ..where((t) => t.playlistId.equals(playlistId) & t.trackId.equals(trackId)))
          .go();

  Future<int> removeTrackEntry(int playlistTrackId) =>
      (delete(playlistTracks)..where((t) => t.id.equals(playlistTrackId))).go();

  // Check if track is liked
  Future<bool> isTrackLiked(int trackId) async {
    final likedPlaylist = await getLikedPlaylist();
    final entry = await (select(playlistTracks)
          ..where((t) => t.playlistId.equals(likedPlaylist.id) & t.trackId.equals(trackId)))
        .getSingleOrNull();
    return entry != null;
  }

  // Toggle Liked status
  Future<bool> toggleLikeTrack({
    required int trackId,
    required int artistId,
    required int albumId,
    required String title,
    required String artistName,
    required String albumName,
    required String coverUrl,
    required int durationMs,
    String? genre,
    String? contributorsJson,
  }) async {
    return transaction(() async {
      final likedPlaylist = await getLikedPlaylist();
      final isLikedCurrently = await isTrackLiked(trackId);

      if (isLikedCurrently) {
        await removeTrackFromPlaylist(likedPlaylist.id, trackId);
        return false;
      } else {
        await addTrackToPlaylist(
          playlistId: likedPlaylist.id,
          trackId: trackId,
          artistId: artistId,
          albumId: albumId,
          title: title,
          artistName: artistName,
          albumName: albumName,
          coverUrl: coverUrl,
          durationMs: durationMs,
          genre: genre,
          contributorsJson: contributorsJson,
        );
        return true;
      }
    });
  }

  // Search inside playlist
  Future<List<PlaylistTrack>> searchTracksInPlaylist(int playlistId, String query) {
    final q = '%${query.toLowerCase()}%';
    return (select(playlistTracks)
          ..where((t) =>
              t.playlistId.equals(playlistId) &
              (t.title.lower().like(q) | t.artistName.lower().like(q))))
        .get();
  }

  /// Una fila de ejemplo por cada `trackId` pedido, mirando en TODAS las
  /// playlists locales.
  ///
  /// Sirve para reconstruir pistas completas (título, artista, portada,
  /// duración) a partir de los IDs sueltos que guarda `listening_history`,
  /// que solo almacena identificadores. Sin esto, armar el mix "On Repeat"
  /// costaría una petición a `/track/{id}` por cada canción; con esto, la
  /// mayoría se resuelven gratis y sin conexión.
  Future<Map<int, PlaylistTrack>> findTracksByIds(Set<int> trackIds) async {
    if (trackIds.isEmpty) return {};
    final rows = await (select(playlistTracks)..where((t) => t.trackId.isIn(trackIds))).get();
    final out = <int, PlaylistTrack>{};
    for (final row in rows) {
      out.putIfAbsent(row.trackId, () => row);
    }
    return out;
  }

  /// Una fila de ejemplo por cada `artistId` pedido, para recuperar el nombre
  /// del artista sin gastar una llamada a `/artist/{id}`.
  Future<Map<int, PlaylistTrack>> findTracksByArtistIds(Set<int> artistIds) async {
    if (artistIds.isEmpty) return {};
    final rows = await (select(playlistTracks)..where((t) => t.artistId.isIn(artistIds))).get();
    final out = <int, PlaylistTrack>{};
    for (final row in rows) {
      out.putIfAbsent(row.artistId, () => row);
    }
    return out;
  }
}
