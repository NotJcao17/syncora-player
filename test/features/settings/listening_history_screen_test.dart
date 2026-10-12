import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/apis/deezer_api.dart';
import 'package:syncora_player/data/apis/deezer_provider.dart';
import 'package:syncora_player/data/local_db/database_provider.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';
import 'package:syncora_player/features/settings/screens/listening_history_screen.dart';

class _FakeApi extends DeezerApi {
  final List<int> asked = [];
  final Set<int> quotaErrors = {};

  @override
  Future<DeezerTrack> getTrack(int id) async {
    asked.add(id);
    if (quotaErrors.contains(id)) throw StateError('Deezer /track/$id: {code: 4}');
    return DeezerTrack(
      id: id,
      title: 'Deezer $id',
      artistName: 'Artista',
      artistId: 1,
      albumTitle: 'Álbum',
      albumId: 1,
      coverUrl: '',
      durationSec: 180,
    );
  }
}

void main() {
  late SyncoraDatabase db;
  late _FakeApi api;
  late ProviderContainer container;

  setUp(() {
    db = SyncoraDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    api = _FakeApi();
    container = ProviderContainer(overrides: [
      syncoraDatabaseProvider.overrideWithValue(db),
      deezerApiProvider.overrideWithValue(api),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<List<ResolvedHistoryItem>> load() {
    final sub = container.listen(resolvedListeningHistoryProvider, (_, _) {});
    addTearDown(sub.close);
    return container.read(resolvedListeningHistoryProvider.future);
  }

  test('H-R8-10: los metadatos salen de las playlists locales y solo lo que falta va a Deezer', () async {
    final playlistId = await db.playlistDao.createPlaylist(title: 'Mía');
    await db.playlistDao.addTrackToPlaylist(
      playlistId: playlistId,
      trackId: 10,
      artistId: 1,
      albumId: 1,
      title: 'Local 10',
      artistName: 'Morat',
      albumName: '23',
      coverUrl: '',
      durationMs: 187000,
    );
    final dao = db.listeningHistoryDao;
    await dao.recordEntry(trackId: 10, artistId: 1, albumId: 1, durationListenedMs: 30000);
    await dao.recordEntry(trackId: 11, artistId: 1, albumId: 1, durationListenedMs: 30000);

    final items = await load();
    expect(items.map((i) => i.track?.title), containsAll(['Local 10', 'Deezer 11']));
    expect(api.asked, [11]);
  });

  test('H-R8-10: un error de Deezer deja la fila sin metadatos, nunca "Desconocida"', () async {
    api.quotaErrors.add(12);
    await db.listeningHistoryDao.recordEntry(trackId: 12, artistId: 1, albumId: 1, durationListenedMs: 30000);
    final items = await load();
    expect(items.single.track, isNull);
  });

  test('H-R8-10: mientras la pantalla está abierta no se vuelve a cargar', () async {
    final dao = db.listeningHistoryDao;
    final current = await dao.recordEntry(trackId: 20, artistId: 1, albumId: 1, durationListenedMs: 30000);
    final states = <AsyncValue<List<ResolvedHistoryItem>>>[];
    container.listen(resolvedListeningHistoryProvider, (_, next) => states.add(next), fireImmediately: true);
    await container.read(resolvedListeningHistoryProvider.future);
    states.clear();

    await dao.updateListenedDuration(current, 60000);
    await dao.recordEntry(trackId: 21, artistId: 1, albumId: 1, durationListenedMs: 30000);
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(states, isEmpty);
    expect(api.asked, [20]);
  });
}
