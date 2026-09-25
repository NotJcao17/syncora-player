import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/apis/deezer_api.dart';
import 'package:syncora_player/data/apis/deezer_provider.dart';
import 'package:syncora_player/data/local_db/database_provider.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/data/models/deezer/deezer_search_result.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';
import 'package:syncora_player/data/supabase/supabase_playlist_repository.dart';
import 'package:syncora_player/data/supabase/supabase_providers.dart';
import 'package:syncora_player/features/library/import_export/import_manager.dart';
import 'package:syncora_player/features/library/import_export/playlist_import_export_service.dart';

/// Cada título "Cancion N" resuelve a la pista de id N; los que empiezan por
/// "Nope" no existen en Deezer.
class _FakeDeezerApi extends DeezerApi {
  static DeezerTrack _track(int id) => DeezerTrack(
        id: id,
        title: 'Cancion $id',
        artistName: 'Artista',
        artistId: 1,
        albumTitle: 'Album',
        albumId: 1,
        coverUrl: '',
        durationSec: 200,
      );

  @override
  Future<DeezerSearchResult> search(String query, {DeezerSearchType type = DeezerSearchType.all, bool enrich = true}) async {
    final m = RegExp(r'Cancion (\d+)').firstMatch(query);
    if (m == null) return const DeezerSearchResult();
    return DeezerSearchResult(tracks: [_track(int.parse(m.group(1)!))]);
  }

  @override
  Future<DeezerTrack> getTrack(int id) async => _track(id);
}

class _FakeRepo extends SupabasePlaylistRepository {
  final uploaded = <int>[];
  bool failUploads = false;
  bool deleted = false;

  @override
  Future<Map<String, dynamic>> createPlaylist({
    required String title,
    String? description,
    bool isPublic = false,
    bool isLiked = false,
    bool isPinned = false,
  }) async =>
      {'id': 'remote_1'};

  @override
  Future<void> addTracksToPlaylist(String playlistId, List<Map<String, dynamic>> tracksData) async {
    if (failUploads) throw Exception('sin red');
    uploaded.addAll(tracksData.map((t) => t['track_id'] as int));
  }

  @override
  Future<void> deletePlaylist(String id) async => deleted = true;
}

List<RawImportTrack> _raw(int count, {Set<int> missing = const {}}) => [
      for (var i = 1; i <= count; i++)
        RawImportTrack(title: missing.contains(i) ? 'Nope $i' : 'Cancion $i', artist: 'Artista'),
    ];

void main() {
  late SyncoraDatabase db;
  late _FakeRepo repo;
  late InMemoryImportJobStore store;
  late ProviderContainer container;

  setUp(() {
    db = SyncoraDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    repo = _FakeRepo();
    store = InMemoryImportJobStore();
    container = ProviderContainer(overrides: [
      syncoraDatabaseProvider.overrideWithValue(db),
      deezerApiProvider.overrideWithValue(_FakeDeezerApi()),
      supabasePlaylistRepositoryProvider.overrideWithValue(repo),
      importJobStoreProvider.overrideWithValue(store),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> waitUntil(bool Function() cond) async {
    for (var i = 0; i < 200 && !cond(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  ImportJob jobOf(int playlistId) =>
      container.read(importManagerProvider).firstWhere((j) => j.playlistId == playlistId);

  test('importa por bloques, en orden, sube a la nube y cuenta las no encontradas', () async {
    final sub = container.listen(importManagerProvider, (_, _) {});
    addTearDown(sub.close);
    final manager = container.read(importManagerProvider.notifier);

    final playlistId = await manager.startImport(title: 'Importada', rawTracks: _raw(25, missing: {3, 17}));
    await waitUntil(() => jobOf(playlistId).status == ImportJobStatus.completed);

    final job = jobOf(playlistId);
    expect(job.status, ImportJobStatus.completed);
    expect(job.matchedCount, 23);
    expect(job.unmatched.length, 2);

    final tracks = await db.playlistDao.getTracksOrdered(playlistId);
    final expected = [for (var i = 1; i <= 25; i++) if (i != 3 && i != 17) i];
    expect(tracks.map((t) => t.trackId).toList(), expected);
    expect(repo.uploaded, expected, reason: 'la nube recibe lo mismo que el dispositivo');
    final playlist = await db.playlistDao.getPlaylistById(playlistId);
    expect(playlist?.remoteId, 'remote_1');
  });

  test('si la nube rechaza un bloque, se pausa sin insertarlo en local', () async {
    final sub = container.listen(importManagerProvider, (_, _) {});
    addTearDown(sub.close);
    repo.failUploads = true;
    final manager = container.read(importManagerProvider.notifier);

    final playlistId = await manager.startImport(title: 'Importada', rawTracks: _raw(5));
    await waitUntil(() => jobOf(playlistId).status == ImportJobStatus.paused);

    expect(jobOf(playlistId).status, ImportJobStatus.paused);
    expect(jobOf(playlistId).nextIndex, 0);
    expect(await db.playlistDao.getTracksOrdered(playlistId), isEmpty);

    repo.failUploads = false;
    manager.resume(jobOf(playlistId).id);
    await waitUntil(() => jobOf(playlistId).status == ImportJobStatus.completed);
    expect((await db.playlistDao.getTracksOrdered(playlistId)).length, 5);
  });

  test('cancelar y borrar elimina la playlist en local y en la nube', () async {
    final sub = container.listen(importManagerProvider, (_, _) {});
    addTearDown(sub.close);
    final manager = container.read(importManagerProvider.notifier);
    final playlistId = await manager.startImport(title: 'Importada', rawTracks: _raw(40));

    await manager.cancel(jobOf(playlistId).id, deletePlaylist: true);

    expect(await db.playlistDao.getPlaylistById(playlistId), isNull);
    expect(repo.deleted, isTrue);
    expect(container.read(importManagerProvider), isEmpty);
    expect(store.jobs, isEmpty);
  });

  test('un trabajo guardado a medias se reanuda al arrancar y no repite lo hecho', () async {
    final playlistId = await db.playlistDao.createPlaylist(title: 'Importada');
    store.jobs['j1'] = ImportJob(
      id: 'j1',
      title: 'Importada',
      playlistId: playlistId,
      remotePlaylistId: null,
      rawTracks: _raw(15),
      nextIndex: 10,
      matchedCount: 10,
      unmatched: const [],
      status: ImportJobStatus.running,
    );

    final sub = container.listen(importManagerProvider, (_, _) {});
    addTearDown(sub.close);
    await waitUntil(() =>
        container.read(importManagerProvider).any((j) => j.id == 'j1' && j.status == ImportJobStatus.completed));

    final tracks = await db.playlistDao.getTracksOrdered(playlistId);
    expect(tracks.map((t) => t.trackId).toList(), [11, 12, 13, 14, 15]);
  });

  test('no deja empezar más de dos importaciones a la vez', () async {
    final sub = container.listen(importManagerProvider, (_, _) {});
    addTearDown(sub.close);
    repo.failUploads = true; // se quedan en pausa: siguen contando como activas
    final manager = container.read(importManagerProvider.notifier);
    expect(manager.canStartImport, isTrue);
    await manager.startImport(title: 'A', rawTracks: _raw(3));
    expect(manager.canStartImport, isTrue);
    await manager.startImport(title: 'B', rawTracks: _raw(3));
    expect(manager.canStartImport, isFalse);
  });
}
