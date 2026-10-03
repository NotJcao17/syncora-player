import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/discover/preview_player.dart';

import '../player/syncora_player_controller_test.dart' show FakeAudioEngine;

void main() {
  test('si la URL de preview caducó, pide la fresca y reintenta una vez', () async {
    final engine = FakeAudioEngine()
      ..throwOnSetUrl = true
      ..failSetUrlTimes = 1;
    final refreshed = <int>[];
    final player = PreviewPlayer(
      engineFactory: () => engine,
      refreshUrl: (id) async {
        refreshed.add(id);
        return 'https://cdnt-preview.dzcdn.net/fresca.mp3';
      },
    );
    addTearDown(player.dispose);

    expect(await player.play(7, 'https://cdnt-preview.dzcdn.net/caducada.mp3'), isTrue);
    expect(refreshed, [7]);
    expect(engine.lastUrl, 'https://cdnt-preview.dzcdn.net/fresca.mp3');
  });

  test('si tampoco la fresca carga, se rinde sin bucle', () async {
    final engine = FakeAudioEngine()..throwOnSetUrl = true;
    final player = PreviewPlayer(engineFactory: () => engine, refreshUrl: (_) async => 'https://x/fresca.mp3');
    addTearDown(player.dispose);

    expect(await player.play(7, 'https://x/caducada.mp3'), isFalse);
    expect(engine.setUrlCallCount, 2);
  });

  test('cambiar de tarjeta mientras carga descarta la carga vieja', () async {
    final engine = FakeAudioEngine();
    final player = PreviewPlayer(engineFactory: () => engine);
    addTearDown(player.dispose);

    final first = player.play(1, 'https://x/1.mp3');
    final second = player.play(2, 'https://x/2.mp3');
    expect(await first, isFalse);
    expect(await second, isTrue);
    expect(player.currentTrackId, 2);
  });
}
