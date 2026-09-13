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

  /// Espeja `SyncoraPlayerController.lastPauseWasUserInitiated`: la pausa que
  /// pide el propio servicio NO es del usuario; la que simula el test con
  /// [pausaManual] sí.
  late bool pausedByUser;
  late AudioFocusService service;

  /// El usuario pulsa pausa a mano (p. ej. abriendo la app en mitad de una
  /// llamada).
  void pausaManual() {
    playing = false;
    pausedByUser = true;
    calls.add('pausa-del-usuario');
  }

  /// El usuario pulsa reproducir a mano.
  void reproduceManual() {
    playing = true;
    pausedByUser = false;
    calls.add('play-del-usuario');
  }

  AudioFocusService build() => AudioFocusService(
        onPause: () async {
          calls.add('pause');
          playing = false;
          pausedByUser = false;
        },
        onResume: () async {
          calls.add('resume');
          playing = true;
          pausedByUser = false;
        },
        isPlaying: () => playing,
        wasPausedByUser: () => pausedByUser,
      );

  setUp(() {
    calls = [];
    playing = true;
    pausedByUser = false;
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

    test('si el usuario pausa a mano DURANTE la interrupcion, NO se reanuda', () async {
      // Revision de la ronda 3 (P1): la version anterior de este test corria
      // una interrupcion entera y solo DESPUES marcaba la app como pausada,
      // asi que nunca metia una accion del usuario entre el `begin` y el
      // `end` de la MISMA interrupcion -- pasaba igual con el bug presente.
      //
      // Escenario real: entra una llamada, la musica se auto-pausa, el
      // usuario abre la app y le da a reproducir y luego a pausa porque no
      // quiere que vuelva. Al colgar, la musica no debe volver sola.
      service.handleInterruption(begin(AudioInterruptionType.pause));
      await pumpEventQueue();
      expect(calls, ['pause']);

      // ... el usuario interviene, con la interrupcion todavia en curso.
      reproduceManual();
      pausaManual();

      service.handleInterruption(end(AudioInterruptionType.pause));
      await pumpEventQueue();

      expect(
        calls.contains('resume'),
        isFalse,
        reason: 'la ultima intencion explicita del usuario fue "pausado"',
      );
    });

    test('si el usuario reanuda a mano durante la interrupcion, no se duplica el play', () async {
      service.handleInterruption(begin(AudioInterruptionType.pause));
      await pumpEventQueue();
      reproduceManual();

      service.handleInterruption(end(AudioInterruptionType.pause));
      await pumpEventQueue();

      expect(calls.contains('resume'), isFalse, reason: 'ya estaba sonando');
    });

    test('si ya estaba pausado antes de la interrupcion, no pasa nada', () async {
      playing = false;
      pausedByUser = true;

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
