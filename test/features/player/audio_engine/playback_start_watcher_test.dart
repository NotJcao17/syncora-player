import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/player/audio_engine/audio_engine_state.dart';
import 'package:syncora_player/features/player/audio_engine/playback_start_watcher.dart';

void main() {
  group('awaitPlaybackStarted', () {
    test('resuelve true en cuanto el motor reporta playing', () async {
      final controller = StreamController<AudioEngineState>.broadcast();
      addTearDown(controller.close);

      final future = awaitPlaybackStarted(controller.stream, const Duration(seconds: 5));

      controller.add(AudioEngineState.initial.copyWith(playing: true));

      expect(await future, isTrue);
    });

    test('resuelve true si el motor pasa a buffering o ready sin estar playing', () async {
      final controller = StreamController<AudioEngineState>.broadcast();
      addTearDown(controller.close);

      final future = awaitPlaybackStarted(controller.stream, const Duration(seconds: 5));
      controller.add(AudioEngineState.initial.copyWith(
        processingState: AudioProcessingState.buffering,
      ));

      expect(await future, isTrue);
    });

    test('resuelve false si nada arranca antes del timeout', () async {
      final controller = StreamController<AudioEngineState>.broadcast();
      addTearDown(controller.close);

      final result = await awaitPlaybackStarted(controller.stream, const Duration(milliseconds: 50));

      expect(result, isFalse);
    });

    test('ignora eventos "idle"/"loading" que no cuentan como arranque real', () async {
      final controller = StreamController<AudioEngineState>.broadcast();
      addTearDown(controller.close);

      final future = awaitPlaybackStarted(controller.stream, const Duration(milliseconds: 200));
      controller.add(AudioEngineState.initial.copyWith(
        processingState: AudioProcessingState.loading,
      ));

      expect(await future, isFalse);
    });
  });
}
