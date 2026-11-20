import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/widgets/multi_playlist_picker.dart';
import 'package:syncora_player/data/local_db/database_provider.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/data/supabase/supabase_playlist_repository.dart';
import 'package:syncora_player/features/library/services/add_to_playlist_service.dart';
import 'package:syncora_player/features/player/player_models.dart';

class _FakeRepo extends SupabasePlaylistRepository {
  /// remoteId -> track_ids subidos.
  final uploads = <String, List<int>>{};
  final Set<String> gone = {};
  int created = 0;

  @override
  Future<Map<String, dynamic>> createPlaylist({
    required String title,
    String? description,
    String? coverUrl,
    bool isPublic = false,
    bool isLiked = false,
    bool isPinned = false,
  }) async =>
      {'id': 'new_${++created}'};

  @override
  Future<void> addTrackToPlaylist(String playlistId, Map<String, dynamic> trackData) async {
    if (gone.contains(playlistId)) throw Exception('violates foreign key');
    uploads.putIfAbsent(playlistId, () => []).add(trackData['track_id'] as int);
  }

  @override
  Future<void> addTracksToPlaylist(String playlistId, List<Map<String, dynamic>> tracksData) async {
    uploads.putIfAbsent(playlistId, () => []).addAll(tracksData.map((t) => t['track_id'] as int));
  }
}

const _song = SyncoraTrack(id: '42', title: 'Canción', artist: 'Artista', album: 'Álbum', duration: Duration(seconds: 200));

void main() {
  late SyncoraDatabase db;
  late _FakeRepo repo;

  setUp(() {
    db = SyncoraDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    repo = _FakeRepo();
  });
  tearDown(() => db.close());

  Future<Playlist> playlist(String title, {String? remoteId}) async {
    final id = await db.playlistDao.createPlaylist(title: title, remoteId: remoteId);
    return (await db.playlistDao.getPlaylistById(id))!;
  }

  test('agrega a varias playlists, en la nube y en local', () async {
    final a = await playlist('A', remoteId: 'ra');
    final b = await playlist('B', remoteId: 'rb');

    final result = await addTrackToPlaylistsSynced(
      dao: db.playlistDao,
      repo: repo,
      playlists: [a, b],
      track: _song,
      contributors: const [],
    );

    expect(result.added.map((p) => p.title), ['A', 'B']);
    expect(repo.uploads, {'ra': [42], 'rb': [42]});
    expect((await db.playlistDao.getTracksOrdered(a.id)).single.trackId, 42);
    expect((await db.playlistDao.getTracksOrdered(b.id)).single.trackId, 42);
    expect(result.message, 'Agregada a 2 playlists');
  });

  test('una playlist que ya no existe en la nube no detiene a las demás', () async {
    final a = await playlist('A', remoteId: 'ra');
    final b = await playlist('B', remoteId: 'rb');
    repo.gone.add('ra');

    final result = await addTrackToPlaylistsSynced(
      dao: db.playlistDao,
      repo: repo,
      playlists: [a, b],
      track: _song,
      contributors: const [],
    );

    expect(result.added.map((p) => p.title), ['B']);
    expect(result.gone.map((p) => p.title), ['A']);
    expect((await db.playlistDao.getTracksOrdered(b.id)).single.trackId, 42);
    expect(result.message, 'Agregada a "B". "A" ya no existe en la nube');
  });

  test('una playlist sin subir se sube con sus canciones antes de agregar la nueva', () async {
    final local = await playlist('Sin red');
    await db.playlistDao.addTrackToPlaylist(
      playlistId: local.id,
      trackId: 7,
      artistId: 1,
      albumId: 1,
      title: 'Vieja',
      artistName: 'X',
      albumName: 'Y',
      coverUrl: '',
      durationMs: 1000,
    );

    final outcome = await addTrackToPlaylistSynced(
      dao: db.playlistDao,
      repo: repo,
      playlist: local,
      track: _song,
      contributors: const [],
    );

    expect(outcome, AddToPlaylistOutcome.added);
    expect(repo.uploads, {'new_1': [7, 42]});
    expect((await db.playlistDao.getPlaylistById(local.id))!.remoteId, 'new_1');
  });

  test('las playlists que ya tienen la canción se detectan por id o por título y artista', () async {
    final byId = await playlist('Por id');
    final byName = await playlist('Por nombre');
    final none = await playlist('Sin ella');
    Future<void> add(int playlistId, int trackId, String title, String artist) => db.playlistDao.addTrackToPlaylist(
          playlistId: playlistId,
          trackId: trackId,
          artistId: 1,
          albumId: 1,
          title: title,
          artistName: artist,
          albumName: '',
          coverUrl: '',
          durationMs: 1,
        );
    await add(byId.id, 42, 'Otro título', 'Otro');
    await add(byName.id, 99, '  canción ', 'ARTISTA');
    await add(none.id, 5, 'Canción', 'Otro artista');

    final ids = await db.playlistDao.playlistIdsContainingSong(42, title: 'Canción', artist: 'Artista');
    expect(ids, {byId.id, byName.id});
  });

  group('MultiPlaylistPicker', () {
    Playlist fake(int id, String title) => Playlist(
          id: id,
          title: title,
          isPublic: false,
          isLiked: false,
          isPinned: false,
          orderIndex: 0,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          isGenerated: false,
          isFollowed: false,
        );

    testWidgets('se eligen varias y se confirma; las que ya la tienen no se pueden elegir', (tester) async {
      List<Playlist>? chosen;
      await tester.pumpWidget(ProviderScope(
        overrides: [syncoraDatabaseProvider.overrideWithValue(db)],
        child: MaterialApp(
        home: Scaffold(
          body: MultiPlaylistPicker(
            playlists: [fake(1, 'Uno'), fake(2, 'Dos'), fake(3, 'Tres')],
            containingIds: const {2},
            onDone: (s) => chosen = s,
          ),
        ),
      )));

      final confirm = find.byKey(const Key('multi_playlist_picker_confirm'));
      expect(tester.widget<ElevatedButton>(confirm).onPressed, isNull, reason: 'sin elegir nada no se confirma');

      await tester.tap(find.text('Uno'));
      await tester.tap(find.text('Dos')); // ya la tiene: no cuenta
      await tester.tap(find.text('Tres'));
      await tester.pump();
      expect(find.text('Agregar a 2 playlists'), findsOneWidget);

      await tester.tap(find.text('Tres')); // desmarcar
      await tester.pump();
      await tester.tap(confirm);
      expect(chosen!.map((p) => p.id), [1]);
    });

    testWidgets('"Nueva playlist" la crea y la deja marcada', (tester) async {
      List<Playlist>? chosen;
      await tester.pumpWidget(ProviderScope(
        overrides: [syncoraDatabaseProvider.overrideWithValue(db)],
        child: MaterialApp(
        home: Scaffold(
          body: MultiPlaylistPicker(
            playlists: [fake(1, 'Uno')],
            onCreate: (title) async => fake(9, title),
            onDone: (s) => chosen = s,
          ),
        ),
      )));

      await tester.tap(find.byKey(const Key('multi_playlist_picker_new')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('multi_playlist_picker_new_name')), 'Recién hecha');
      await tester.tap(find.byKey(const Key('multi_playlist_picker_create')));
      await tester.pumpAndSettle();

      expect(find.text('Recién hecha'), findsOneWidget);
      await tester.tap(find.byKey(const Key('multi_playlist_picker_confirm')));
      expect(chosen!.map((p) => p.id), [9]);
    });
  });
}
