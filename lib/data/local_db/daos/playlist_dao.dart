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

  /// Playlist local asociada a [remoteId], o `null`.
  ///
  /// Devuelve la **primera** (id más bajo) en vez de exigir que haya
  /// exactamente una. Bug real encontrado en pruebas: si la base llegaba a
  /// tener dos filas con el mismo `remoteId`, `getSingleOrNull()` lanzaba, el
  /// `catch` vacío de `SyncService` se comía la excepción y la sincronización
  /// quedaba rota en silencio para siempre — reabrir la app no la arreglaba.
  /// La causa de esas filas duplicadas ya está corregida (guarda de
  /// reentrancia en `SyncService`), pero esto evita que un estado sucio
  /// cualquiera vuelva a dejar el sync inutilizable.
  Future<Playlist?> getPlaylistByRemoteId(String remoteId) async {
    final rows = await (select(playlists)
          ..where((t) => t.remoteId.equals(remoteId))
          ..orderBy([(t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc)])
          ..limit(1))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  Future<Playlist> getLikedPlaylist() async {
    // Misma razón que en [getPlaylistByRemoteId]: tolerar más de una fila en
    // vez de lanzar. Si hubiera dos "Tus me gusta", [repairDuplicates] las
    // fusiona; mientras tanto, esto devuelve siempre la misma (la más
    // antigua) para que nada escriba en una y lea de la otra.
    final likedRows = await (select(playlists)
          ..where((t) => t.isLiked.equals(true))
          ..orderBy([(t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc)])
          ..limit(1))
        .get();
    final existing = likedRows.isEmpty ? null : likedRows.first;
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
    String? sourceRef,
    bool isGenerated = false,
  }) async {
    return into(playlists).insert(
      PlaylistsCompanion.insert(
        title: title,
        description: Value(description),
        coverUrl: Value(coverUrl),
        remoteId: Value(remoteId),
        isPublic: Value(isPublic),
        sourceRef: Value(sourceRef),
        isGenerated: Value(isGenerated),
      ),
    );
  }

  /// Playlist creada a partir de [sourceRef] exacto, o `null`.
  ///
  /// Es lo que permite que el botón de guardar aparezca ya en estado
  /// "Guardada": antes no había forma de saber que la copia existía, así que
  /// el usuario volvía a pulsarlo y la playlist se duplicaba en su biblioteca.
  Future<Playlist?> getPlaylistBySourceRef(String sourceRef) async {
    final rows = await (select(playlists)
          ..where((t) => t.sourceRef.equals(sourceRef))
          ..orderBy([(t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc)])
          ..limit(1))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  /// Playlist generada por la app cuyo `sourceRef` empieza por [prefix].
  ///
  /// Se busca por prefijo porque el `sourceRef` de "On Repeat" lleva pegado el
  /// periodo que generó su contenido (`mix:on_repeat:2026-W38`), y así la
  /// misma consulta sirve para encontrarla y para saber si toca regenerarla.
  Future<Playlist?> getGeneratedPlaylist(String prefix) async {
    final rows = await (select(playlists)
          ..where((t) => t.isGenerated.equals(true) & t.sourceRef.like('$prefix%'))
          ..orderBy([(t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc)])
          ..limit(1))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  /// Reemplaza de una sola vez todas las pistas de una playlist.
  ///
  /// Usado por la regeneración de "On Repeat". En una transacción y con los
  /// `orderIndex` calculados de antemano: `addTrackToPlaylist` relee la lista
  /// entera en cada inserción para saber el siguiente índice, lo que para 30
  /// pistas serían 30 lecturas completas.
  Future<void> replaceTracks(int playlistId, List<PlaylistTracksCompanion> tracks) {
    return transaction(() async {
      await (delete(playlistTracks)..where((t) => t.playlistId.equals(playlistId))).go();
      for (var i = 0; i < tracks.length; i++) {
        await into(playlistTracks).insert(
          tracks[i].copyWith(playlistId: Value(playlistId), orderIndex: Value(i)),
        );
      }
    });
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
    // `getSingleOrNull` lanzaría si la pista estuviera repetida dentro de la
    // playlist; un corazón no debe reventar por un estado sucio que
    // [repairDuplicates] ya sabe limpiar.
    final entries = await (select(playlistTracks)
          ..where((t) => t.playlistId.equals(likedPlaylist.id) & t.trackId.equals(trackId))
          ..limit(1))
        .get();
    return entries.isNotEmpty;
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

  /// Repara duplicados locales: playlists que comparten `remoteId`, varias
  /// "Tus me gusta", y la misma pista repetida dentro de una playlist.
  ///
  /// Existe por un bug real de concurrencia en `SyncService` (ya corregido con
  /// una guarda de reentrancia): tres disparadores distintos podían lanzar
  /// `syncLibrary` a la vez — iniciar sesión, arrancar la app y abrir
  /// Biblioteca — y como el flag de "ya sincronizado" se escribía recién al
  /// final, las tres corridas pasaban el chequeo, las tres veían la base local
  /// vacía y las tres insertaban. Resultado en una instalación nueva sobre una
  /// cuenta ya poblada: cada playlist por duplicado y cada pista de "Tus me
  /// gusta" por duplicado.
  ///
  /// Arreglar la causa no limpia las bases que ya quedaron sucias, así que
  /// esto corre en cada arranque. Es barato cuando no hay nada que reparar y
  /// **solo toca lo local**: no borra nada en Supabase, porque los duplicados
  /// se crearon acá, no allá.
  ///
  /// Devuelve cuántas filas eliminó.
  Future<int> repairDuplicates() async {
    var removed = 0;

    final all = await getAllPlaylists();

    // 1. Playlists que comparten `remoteId`: se conserva la más antigua.
    final byRemoteId = <String, List<Playlist>>{};
    for (final playlist in all) {
      final remoteId = playlist.remoteId;
      if (remoteId == null || remoteId.isEmpty) continue;
      (byRemoteId[remoteId] ??= []).add(playlist);
    }

    final toDelete = <int>{};
    for (final group in byRemoteId.values) {
      if (group.length <= 1) continue;
      final sorted = List<Playlist>.from(group)..sort((a, b) => a.id.compareTo(b.id));
      for (final extra in sorted.skip(1)) {
        // Las "Tus me gusta" sobrantes las trata el bloque siguiente, para no
        // borrar por error la única que el resto de la app espera encontrar.
        if (!extra.isLiked) toDelete.add(extra.id);
      }
    }

    // 2. Varias "Tus me gusta": igual, se conserva la más antigua.
    final liked = all.where((p) => p.isLiked).toList()..sort((a, b) => a.id.compareTo(b.id));
    for (final extra in liked.skip(1)) {
      toDelete.add(extra.id);
    }

    for (final id in toDelete) {
      removed += await deletePlaylist(id);
    }

    // 3. La misma pista repetida dentro de una playlist: se conserva la
    //    primera aparición (el `orderIndex` más bajo).
    final survivors = await getAllPlaylists();
    for (final playlist in survivors) {
      final tracks = await getTracksOrdered(playlist.id);
      final seen = <int>{};
      for (final track in tracks) {
        if (seen.add(track.trackId)) continue;
        removed += await removeTrackEntry(track.id);
      }
    }

    return removed;
  }
}
