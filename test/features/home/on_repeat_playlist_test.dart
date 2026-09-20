import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/features/home/mixes/on_repeat_service.dart';

/// "On Repeat" pasó de ser un mix efímero a una playlist permanente que la app
/// mantiene, como "Tus me gusta". Esto cubre las propiedades de la fila que
/// sostienen esa decisión, sin levantar la red ni Riverpod.
void main() {
  late SyncoraDatabase db;

  setUp(() {
    db = SyncoraDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  });

  tearDown(() async => db.close());

  Future<int> createOnRepeat(String periodKey) => db.playlistDao.createPlaylist(
        title: onRepeatTitle,
        sourceRef: '$onRepeatSourcePrefix:$periodKey',
        isGenerated: true,
      );

  PlaylistTracksCompanion track(int id) => PlaylistTracksCompanion.insert(
        playlistId: 0,
        trackId: id,
        artistId: 1,
        albumId: 1,
        title: 'Pista $id',
        artistName: 'Artista',
        albumName: 'Álbum',
        coverUrl: '',
        durationMs: 180000,
      );

  test('se encuentra por prefijo, sin importar el periodo que la generó', () async {
    await createOnRepeat('2026-W38');

    final found = await db.playlistDao.getGeneratedPlaylist(onRepeatSourcePrefix);
    expect(found?.title, onRepeatTitle);
    expect(found?.isGenerated, isTrue);
  });

  test('el sourceRef lleva el periodo, que es lo que decide si toca regenerar', () async {
    await createOnRepeat('2026-W38');
    final found = await db.playlistDao.getGeneratedPlaylist(onRepeatSourcePrefix);

    expect(found?.sourceRef, '$onRepeatSourcePrefix:2026-W38');
    expect(found?.sourceRef == '$onRepeatSourcePrefix:2026-W39', isFalse);
  });

  test('nunca se sube: nace sin remoteId', () async {
    await createOnRepeat('2026-W38');
    final found = await db.playlistDao.getGeneratedPlaylist(onRepeatSourcePrefix);

    // `SyncService` solo poda playlists que SÍ tienen `remoteId`, así que con
    // este null la playlist generada le es invisible.
    expect(found?.remoteId, isNull);
  });

  test('replaceTracks deja exactamente el contenido nuevo, en orden', () async {
    final id = await createOnRepeat('2026-W38');
    await db.playlistDao.replaceTracks(id, [track(1), track(2), track(3)]);
    await db.playlistDao.replaceTracks(id, [track(9), track(8)]);

    final tracks = await db.playlistDao.getTracksOrdered(id);
    expect(tracks.map((t) => t.trackId).toList(), [9, 8]);
    expect(tracks.map((t) => t.orderIndex).toList(), [0, 1]);
  });

  test('una playlist normal no se confunde con la generada', () async {
    await db.playlistDao.createPlaylist(title: onRepeatTitle);

    expect(await db.playlistDao.getGeneratedPlaylist(onRepeatSourcePrefix), isNull);
  });

  test('getPlaylistBySourceRef distingue copias de fuentes distintas', () async {
    await db.playlistDao.createPlaylist(title: 'Top Mexico', sourceRef: 'deezer_playlist:111');
    await db.playlistDao.createPlaylist(title: 'Top USA', sourceRef: 'deezer_playlist:222');

    final found = await db.playlistDao.getPlaylistBySourceRef('deezer_playlist:222');
    expect(found?.title, 'Top USA');
    expect(await db.playlistDao.getPlaylistBySourceRef('deezer_playlist:333'), isNull);
  });
}
