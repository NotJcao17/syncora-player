import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/player_providers.dart';
import 'package:syncora_player/features/player/syncora_player_controller.dart';
import 'package:syncora_player/features/player/widgets/shuffle_toggle_button.dart';

import 'mini_player_test.dart' show FakeAudioEngine, FakeExtractionService;

void main() {
  testWidgets('el aleatorio de una cabecera solo cambia el modo: no pone nada a sonar', (tester) async {
    final engine = FakeAudioEngine();
    final controller = SyncoraPlayerController(engine: engine, extractionService: FakeExtractionService());
    const playing = SyncoraTrack(id: 'a', title: 'Sonando');
    await controller.setQueue([playing, const SyncoraTrack(id: 'b', title: 'Otra')], autoplay: false);

    final container = ProviderContainer(overrides: [syncoraPlayerControllerProvider.overrideWith((ref) => controller)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ShuffleToggleButton())),
    ));

    await tester.tap(find.byType(ShuffleToggleButton));
    await tester.pump();
    expect(controller.state.isShuffle, isTrue);
    expect(controller.state.currentTrack?.id, 'a', reason: 'la cola no se reemplaza');
    expect(controller.state.engine.playing, isFalse, reason: 'tocar aleatorio no reproduce');

    await tester.tap(find.byType(ShuffleToggleButton));
    await tester.pump();
    expect(controller.state.isShuffle, isFalse);
  });
}
