import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/settings/app_settings_store.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/unplayable_track_log.dart';

void main() {
  test('guarda la más reciente primero y sobrevive a recrear el registro', () {
    final store = AppSettingsStore.inMemory();
    final log = UnplayableTrackLog(store);
    log.record(const SyncoraTrack(id: '1', title: 'Crazy In Love', artist: 'Beyoncé'), 'No se encontró en YouTube',
        at: DateTime(2026, 10, 21, 22, 5));
    log.record(const SyncoraTrack(id: '2', title: 'End of Beginning', artist: 'Djo'), 'Se cortó la reproducción',
        at: DateTime(2026, 10, 21, 22, 9));

    final again = UnplayableTrackLog(store);
    expect(again.entries.map((e) => e.title), ['End of Beginning', 'Crazy In Love']);
    expect(again.entries.first.reason, 'Se cortó la reproducción');
    expect(again.entries.first.at, DateTime(2026, 10, 21, 22, 9));
  });

  test('se queda con las 50 más recientes y se puede vaciar', () {
    final store = AppSettingsStore.inMemory();
    final log = UnplayableTrackLog(store);
    for (var i = 0; i < 60; i++) {
      log.record(SyncoraTrack(id: '$i', title: 'T$i'), 'x');
    }
    expect(log.entries, hasLength(UnplayableTrackLog.maxEntries));
    expect(log.entries.first.title, 'T59');

    log.clear();
    expect(UnplayableTrackLog(store).entries, isEmpty);
  });

  test('un registro dañado no rompe nada', () async {
    final store = AppSettingsStore.inMemory();
    await store.setString(UnplayableTrackLog.storageKey, '{no es json');
    expect(UnplayableTrackLog(store).entries, isEmpty);
  });
}
