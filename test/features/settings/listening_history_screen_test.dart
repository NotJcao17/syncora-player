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

class _CountingApi extends DeezerApi {
  int calls = 0;

  @override
  Future<DeezerTrack> getTrack(int id) async {
    calls++;
    return DeezerTrack(
      id: id,
      title: 'Canción $id',
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
  test('H-R8-10: el volcado de duración de la escucha en curso no vuelve a cargar el historial', () async {
    final db = SyncoraDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    final api = _CountingApi();
    final container = ProviderContainer(overrides: [
      syncoraDatabaseProvider.overrideWithValue(db),
      deezerApiProvider.overrideWithValue(api),
    ]);
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    final dao = db.listeningHistoryDao;
    await dao.recordEntry(trackId: 10, artistId: 1, albumId: 1, durationListenedMs: 30000);
    final current = await dao.recordEntry(trackId: 11, artistId: 1, albumId: 1, durationListenedMs: 30000);

    final states = <AsyncValue<List<ResolvedHistoryItem>>>[];
    container.listen(resolvedListeningHistoryProvider, (_, next) => states.add(next), fireImmediately: true);
    await _settle(container);
    expect(container.read(resolvedListeningHistoryProvider).value?.length, 2);
    final callsAfterLoad = api.calls;
    states.clear();

    // Volcado periódico de la escucha en curso: solo cambia la duración.
    await dao.updateListenedDuration(current, 45000);
    await dao.updateListenedDuration(current, 60000);
    await _settle(container);
    expect(states, isEmpty, reason: 'la lista visible no cambió');
    expect(api.calls, callsAfterLoad);

    // Una escucha nueva solo pide la canción nueva y no vuelve al esqueleto.
    await dao.recordEntry(trackId: 12, artistId: 1, albumId: 1, durationListenedMs: 30000);
    await _settle(container);
    expect(api.calls, callsAfterLoad + 1);
    expect(container.read(resolvedListeningHistoryProvider).value?.length, 3);
  });
}

Future<void> _settle(ProviderContainer container) async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
