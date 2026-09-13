import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/player/audio_focus_service.dart';

/// Ronda 3, A1 (hallazgo H-R3-1).
///
/// La app no manejaba foco de audio en absoluto: `audio_session` estaba solo
/// como dependencia transitiva y sin un solo uso en `lib/`. Estos tests fijan
/// la maquina de estados que decide cuando se pausa y, sobre todo, **cuando NO
/// se reanuda** -- que es la parte facil de romper.
///
/// Se ejercita `handleInterruption` directamente (no `attach()`) para no
/// depender del plugin nativo, siguiendo el mismo criterio que el resto de la
/// suite.
void main() {
  late List<String> calls;
  late bool playing;
  late AudioFocusService service;

  AudioFocusService build() => AudioFocusService(
        onPause: () async {
          calls.add('pause');
          playing = false;
        },
        onResume: () async {
          calls.add('resume');
          playing = true;
        },
        isPlaying: () => playing,
      );

  setUp(() {
    calls = [];
    playing = true;
    service = build();
  });

  tearDown(() => service.dispose());

  AudioInterruptionEvent begin(AudioInterruptionType type) =>
      AudioInterruptionEvent(true, type);
  AudioInterruptionEvent end(AudioInterruptionType type) =>
      AudioInterruptionEvent(false, type);

  group('Interrupcion transitoria (alarma, llamada, audio de otra app)', () {
    test('pausa al empezar y reanuda al terminar', () async {
      service.handleInterruption(begin(AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(calls, ['pause']);

      service.handleInterruption(end(AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(calls, ['pause', 'resume']);
    });

    test('si el usuario pausa durante la interrupcion, NO se reanuda solo', () async {
      // Este es el caso que hace falta proteger: el usuario decide pausar
      // mientras suena la alarma. Al acabar la alarma la musica no debe
      // volver sola -- la ultima intencion explicita fue "pausado".
      service.handleInterruption(begin(AudioInterruptionType.pause));
      await pumpEventQueue();

      // Una interrupcion nueva que llega ya con la app pausada no vuelve a
      // marcar "pausado por interrupcion"...
      service.handleInterruption(end(AudioInterruptionType.pause));
      await pumpEventQueue();
      calls.clear();
      playing = false;

      service.handleInterruption(begin(AudioInterruptionType.pause));
      service.handleInterruption(end(AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(calls, isEmpty, reason: 'nada que pausar ni que reanudar');
    });

    test('la marca no sobrevive a la interrupcion', () async {
      service.handleInterruption(begin(AudioInterruptionType.pause));
      service.handleInterruption(end(AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(service.pausedByInterruption, isFalse);
    });
  });

  group('Perdida permanente de foco', () {
    test('pausa, pero nunca reanuda', () async {
      service.handleInterruption(begin(AudioInterruptionType.unknown));
      await pumpEventQueue();
      expect(calls, ['pause']);

      service.handleInterruption(end(AudioInterruptionType.unknown));
      await pumpEventQueue();
      expect(calls, ['pause'], reason: 'otra app se quedo con la reproduccion');
    });
  });

  group('Duck', () {
    test('no toca la reproduccion: Android atenua por su cuenta', () async {
      service.handleInterruption(begin(AudioInterruptionType.duck));
      service.handleInterruption(end(AudioInterruptionType.duck));
      await pumpEventQueue();
      expect(calls, isEmpty);
    });
  });

  group('Salida de audio desconectada', () {
    test('pausa al desconectar auriculares', () async {
      service.handleBecomingNoisy();
      await pumpEventQueue();
      expect(calls, ['pause']);
    });

    test('no reanuda al reconectar: no marca pausa por interrupcion', () async {
      service.handleBecomingNoisy();
      await pumpEventQueue();
      expect(service.pausedByInterruption, isFalse);
    });

    test('no hace nada si ya estaba pausado', () async {
      playing = false;
      service.handleBecomingNoisy();
      await pumpEventQueue();
      expect(calls, isEmpty);
    });
  });

  test('tras dispose no reacciona a nada', () async {
    service.dispose();
    service.handleInterruption(begin(AudioInterruptionType.pause));
    service.handleBecomingNoisy();
    await pumpEventQueue();
    expect(calls, isEmpty);
  });
}
