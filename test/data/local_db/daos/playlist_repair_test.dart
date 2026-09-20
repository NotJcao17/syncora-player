import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';

/// Cobertura del bug real encontrado en pruebas en dispositivo: instalar la app
/// de cero sobre una cuenta ya poblada dejaba cada playlist y cada "me gusta"
/// por duplicado, porque tres disparadores de `syncLibrary` corrían a la vez.
/// La causa ya está cerrada con una guarda de reentrancia en `SyncService`;
/// esto cubre la reparación, que es lo que sana las bases ya sucias.
void main() {
  late SyncoraDatabase db;

  setUp(() {
    db = SyncoraDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  });

  tearDown(() async => db.close());

  Future<int> addTrack(int playlistId, int trackId) => db.playlistDao.addTrackToPlaylist(
        playlistId: playlistId,
        trackId: trackId,
        artistId: 1,
        albumId: 1,
        title: 'Pista $trackId',
        artistName: 'Artista',
        albumName: 'Álbum',
        coverUrl: '',
        durationMs: 180000,
      );

  test('fusiona playlists que comparten remoteId y conserva la más antigua', () async {
    final first = await db.playlistDao.createPlaylist(title: 'Importada', remoteId: 'r1');
    final second = await db.playlistDao.createPlaylist(title: 'Importada', remoteId: 'r1');

    await db.playlistDao.repairDuplicates();

    final remaining = await db.playlistDao.getAllPlaylists();
    final ids = remaining.map((p) => p.id).toSet();
    expect(ids.contains(first), isTrue);
    expect(ids.contains(second), isFalse);
  });

  test('deja una sola "Tus me gusta" aunque haya varias', () async {
    // `onCreate` ya inserta la oficial; se simula la segunda que creaba la
    // corrida concurrente.
    await db.into(db.playlists).insert(
          PlaylistsCompanion.insert(
            title: 'Tus me gusta',
            isLiked: const Value(true),
          ),
        );

    await db.playlistDao.repairDuplicates();

    final liked = (await db.playlistDao.getAllPlaylists()).where((p) => p.isLiked).toList();
    expect(liked.length, 1);
  });

  test('quita la misma pista repetida dentro de una playlist', () async {
    final playlist = await db.playlistDao.createPlaylist(title: 'Con duplicados');
    await addTrack(playlist, 100);
    await addTrack(playlist, 100);
    await addTrack(playlist, 200);

    final removed = await db.playlistDao.repairDuplicates();

    final tracks = await db.playlistDao.getTracksOrdered(playlist);
    expect(removed, 1);
    expect(tracks.map((t) => t.trackId).toList(), [100, 200]);
  });

  test('no toca una base sana', () async {
    final playlist = await db.playlistDao.createPlaylist(title: 'Sana', remoteId: 'r9');
    await addTrack(playlist, 1);
    await addTrack(playlist, 2);

    final removed = await db.playlistDao.repairDuplicates();

    expect(removed, 0);
    expect((await db.playlistDao.getTracksOrdered(playlist)).length, 2);
  });

  test('getPlaylistByRemoteId no lanza con filas duplicadas', () async {
    await db.playlistDao.createPlaylist(title: 'A', remoteId: 'dup');
    await db.playlistDao.createPlaylist(title: 'B', remoteId: 'dup');

    // Antes usaba `getSingleOrNull()`: esto lanzaba, `SyncService` se comía la
    // excepción y la sincronización quedaba rota en silencio para siempre.
    final found = await db.playlistDao.getPlaylistByRemoteId('dup');
    expect(found, isNotNull);
  });
}
