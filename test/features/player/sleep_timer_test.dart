import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/player/audio_engine/audio_engine_state.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/player_providers.dart';
import 'package:syncora_player/features/player/sleep_timer.dart';
import 'package:syncora_player/features/player/syncora_player_controller.dart';

class _FakeTarget implements SleepTimerTarget {
  @override
  bool isPlaying = true;
  @override
  double volume = 0.8;
  final volumes = <double>[];
  int pauses = 0;

  @override
  Future<void> setVolume(double v) async {
    volume = v;
    volumes.add(v);
  }

  @override
  Future<void> pause() async {
    pauses++;
    isPlaying = false;
  }
}

const _trackA = SyncoraTrack(id: 'a', title: 'A', artist: 'X');
const _trackB = SyncoraTrack(id: 'b', title: 'B', artist: 'X');

SyncoraPlayerState _playing(SyncoraTrack track, {Duration position = Duration.zero, bool playing = true}) {
  return SyncoraPlayerState(
    currentTrack: track,
    engine: AudioEngineState(playing: playing, position: position, duration: const Duration(minutes: 3)),
  );
}

void main() {
  late _FakeTarget target;
  late StateProvider<SyncoraPlayerState> fakeState;
  late ProviderContainer container;

  setUp(() {
    target = _FakeTarget();
    fakeState = StateProvider<SyncoraPlayerState>((ref) => _playing(_trackA));
    container = ProviderContainer(
      overrides: [
        sleepTimerTargetProvider.overrideWithValue(target),
        playerStateProvider.overrideWith((ref) => ref.watch(fakeState)),
      ],
    );
    addTearDown(container.dispose);
  });

  SleepTimerNotifier notifier() => container.read(sleepTimerProvider.notifier);
  // Riverpod propaga el cambio a los dependientes en una tarea aparte.
  void emit(FakeAsync async, SyncoraPlayerState s) {
    container.read(fakeState.notifier).state = s;
    async.elapse(const Duration(milliseconds: 20));
  }

  test('timed: fades out, pauses and restores the volume', () {
    fakeAsync((async) {
      notifier().startTimed(const Duration(minutes: 15));
      expect(container.read(sleepTimerProvider).mode, SleepTimerMode.timed);

      async.elapse(const Duration(minutes: 14, seconds: 59));
      expect(target.pauses, 0);

      async.elapse(const Duration(seconds: 1) + SleepTimerNotifier.fadeDuration + const Duration(seconds: 1));
      expect(target.pauses, 1);
      expect(target.volumes.first, lessThan(0.8));
      expect(target.volume, 0.8);
      expect(container.read(sleepTimerProvider).isActive, isFalse);
    });
  });

  test('cancel before expiry does nothing', () {
    fakeAsync((async) {
      notifier().startTimed(const Duration(minutes: 5));
      notifier().cancel();
      async.elapse(const Duration(minutes: 10));
      expect(target.pauses, 0);
      expect(target.volumes, isEmpty);
    });
  });

  test('cancel during the fade restores volume without pausing', () {
    fakeAsync((async) {
      notifier().startTimed(const Duration(minutes: 5));
      async.elapse(const Duration(minutes: 5, seconds: 3));
      notifier().cancel();
      async.elapse(SleepTimerNotifier.fadeDuration);
      expect(target.pauses, 0);
      expect(target.volume, 0.8);
    });
  });

  test('end of track: pauses right before the end', () {
    fakeAsync((async) {
      notifier().startEndOfTrack();
      emit(async, _playing(_trackA, position: const Duration(minutes: 2)));
      expect(target.pauses, 0);
      emit(async, _playing(_trackA, position: const Duration(minutes: 2, seconds: 59)));
      expect(target.pauses, 1);
      expect(container.read(sleepTimerProvider).isActive, isFalse);
    });
  });

  test('end of track: on track change, waits until the new one plays', () {
    fakeAsync((async) {
      notifier().startEndOfTrack();
      // Siguiente pista cargando (todavía sin sonar): pausar ahora no sirve.
      emit(async, _playing(_trackB, playing: false));
      expect(target.pauses, 0);
      emit(async, _playing(_trackB));
      expect(target.pauses, 1);
    });
  });
}
