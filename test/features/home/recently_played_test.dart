import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/database_provider.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/features/home/home_providers.dart';

void main() {
  // Ronda 10 (PC): Inicio calculaba "Escuchado recientemente" una sola vez.
  // Si eso pasaba con la biblioteca a medio sincronizar, se quedaba con una
  // sola playlist y con ids locales que el sync después reemplazaba: al
  // tocarla salía "Playlist eliminada".
  test('sigue a la base: si el sync recrea las playlists, Inicio apunta a las nuevas', () async {
    final db = SyncoraDatabase(NativeDatabase.memory());
    final container = ProviderContainer(overrides: [syncoraDatabaseProvider.overrideWithValue(db)]);
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    final dao = db.playlistDao;

    // Biblioteca a medias: solo una playlist reproducida.
    final first = await dao.createPlaylist(title: '2026', remoteId: 'r-2026');
    await dao.touchLastPlayed(first);

    final sub = container.listen(recentlyPlayedProvider, (_, _) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    expect(container.read(recentlyPlayedProvider).value!.map((i) => i.route), ['/playlist/$first']);

    // El sync borra y vuelve a crear (otro id local) y llegan más playlists.
    await dao.deletePlaylist(first);
    final recreated = await dao.createPlaylist(title: '2026', remoteId: 'r-2026');
    final other = await dao.createPlaylist(title: 'CHILL', remoteId: 'r-chill');
    await dao.touchLastPlayed(recreated);
    await dao.touchLastPlayed(other);
    await pumpEventQueue();

    final routes = container.read(recentlyPlayedProvider).value!.map((i) => i.route).toList();
    expect(routes, unorderedEquals(['/playlist/$other', '/playlist/$recreated']));
    expect(routes, isNot(contains('/playlist/$first')));
  });
}
