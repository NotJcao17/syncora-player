import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/player/audio_engine/audio_engine_state.dart';
import 'package:syncora_player/features/player/audio_engine/crossfade_audio_engine.dart';

// `FakeAudioEngine` ya está definida en syncora_player_controller_test.dart
// (mismo patrón que el resto de fakes de la suite) — se importa con `show`
// para evitar el choque de `main()` entre ambos archivos de test.
import '../syncora_player_controller_test.dart' show FakeAudioEngine;

void main() {
  group('CrossfadeAudioEngine', () {
    late List<FakeAudioEngine> createdEngines;
    late List<List<double>> volumeHistories;
    late Duration fadeDurationSetting;
    late CrossfadeAudioEngine engine;

    FakeAudioEngine createTrackedEngine() {
      final e = FakeAudioEngine();
      createdEngines.add(e);
      final history = <double>[];
      volumeHistories.add(history);
      e.stateStream.listen((s) => history.add(s.volume));
      return e;
    }

    setUp(() {
      createdEngines = [];
      volumeHistories = [];
      fadeDurationSetting = Duration.zero;
      engine = CrossfadeAudioEngine(
        createEngine: createTrackedEngine,
        fadeDurationGetter: () => fadeDurationSetting,
      );
    });

    tearDown(() {
      engine.dispose();
    });

    test('crea únicamente _active al construirse; _standby es perezoso', () {
      expect(createdEngines.length, 1,
          reason: 'no debe gastarse una segunda instancia nativa sin que haya un crossfade real');
    });

    test('métodos normales delegan a _active sin diferencia observable', () async {
      await engine.setUrl('https://example.com/a.mp3', headers: const {'x': '1'});
      await engine.setLocalSource('/local/a.mp3');
      await engine.play();
      await engine.pause();
      await engine.seek(const Duration(seconds: 10));
      await engine.setSpeed(1.5);
      await engine.setVolume(0.5);
      await engine.setSkipSilenceEnabled(true);
      await engine.stop();

      expect(createdEngines.length, 1, reason: 'ninguno de estos métodos debe crear _standby');
      final active = createdEngines.single;
      expect(active.lastUrl, 'https://example.com/a.mp3');
      expect(active.setUrlCallCount, 1);
      expect(active.lastLocalSourcePath, '/local/a.mp3');
      expect(active.setLocalSourceCallCount, 1);
      expect(active.playCallCount, 1);
      expect(active.pauseCallCount, 1);
      expect(active.stopCallCount, 1);
      expect(engine.position, active.position);
      expect(engine.duration, active.duration);
    });

    test('crossfadeToLocalSource resuelve rápido y ya dejó a _standby cargando + reproduciendo '
        '(P1: no debe bloquear al llamador por toda la duración del fade)', () async {
      fadeDurationSetting = const Duration(seconds: 4);
      final sw = Stopwatch()..start();
      await engine.crossfadeToLocalSource('/local/next.mp3', const Duration(seconds: 4));
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(500),
          reason: 'crossfadeToLocalSource debe resolver casi de inmediato; el ramp de volumen '
              'sigue en segundo plano, no debe bloquear al llamador por los 4s configurados');
      expect(createdEngines.length, 2, reason: 'el crossfade debe crear _standby perezosamente');
      final incoming = createdEngines[1];
      expect(incoming.lastLocalSourcePath, '/local/next.mp3');
      expect(incoming.setLocalSourceCallCount, 1);
      expect(incoming.playCallCount, 1);

      await engine.debugAwaitFadeSettled();
    });

    test('el stateStream/posición del wrapper reflejan la pista ENTRANTE desde el arranque del '
        'fade, no recién al final', () async {
      await engine.crossfadeToLocalSource('/local/next.mp3', const Duration(seconds: 2));

      // El swap ya ocurrió dentro de la parte "rápida" de crossfadeToLocalSource
      // (antes de que el ramp de volumen en background siquiera empiece) — el
      // motor que ahora es _active debe ser el que era _standby.
      final incoming = createdEngines[1];
      expect(engine.position, incoming.position);
      expect(engine.duration, incoming.duration);

      final emitted = <AudioEngineState>[];
      engine.stateStream.listen(emitted.add);
      incoming.emitState(const AudioEngineState(position: Duration(seconds: 5)));
      await pumpEventQueue();
      expect(emitted.any((s) => s.position == const Duration(seconds: 5)), isTrue,
          reason: 'una actualización del motor entrante debe llegar al wrapper de inmediato, '
              'sin esperar a que el ramp de volumen termine');

      await engine.debugAwaitFadeSettled();
    });

    test('los volúmenes de ambos motores se mueven en direcciones opuestas durante el ramp en '
        'segundo plano', () async {
      await engine.crossfadeToLocalSource('/local/next.mp3', const Duration(milliseconds: 150));
      await engine.debugAwaitFadeSettled();

      final outgoingVolumes = volumeHistories[0];
      final incomingVolumes = volumeHistories[1];

      expect(outgoingVolumes, isNotEmpty);
      expect(incomingVolumes, isNotEmpty);

      // El entrante arranca silenciado (0.0, antes de sonar) y termina en
      // volumen completo (1.0, el canónico por defecto). El saliente
      // termina en 0.0 y, en conjunto, arrancó más alto de lo que terminó.
      expect(incomingVolumes.first, 0.0);
      expect(incomingVolumes.last, 1.0);
      expect(outgoingVolumes.last, 0.0);
      expect(outgoingVolumes.first, greaterThan(outgoingVolumes.last),
          reason: 'el saliente debe terminar más silencioso de lo que arrancó la transición');

      for (var i = 1; i < outgoingVolumes.length; i++) {
        expect(outgoingVolumes[i], lessThanOrEqualTo(outgoingVolumes[i - 1]));
      }
      for (var i = 1; i < incomingVolumes.length; i++) {
        expect(incomingVolumes[i], greaterThanOrEqualTo(incomingVolumes[i - 1]));
      }
    });

    test('al terminar el ramp en segundo plano, el motor viejo (ahora standby) recibe stop()',
        () async {
      await engine.crossfadeToLocalSource('/local/next.mp3', const Duration(milliseconds: 100));
      await engine.debugAwaitFadeSettled();

      final outgoing = createdEngines[0];
      expect(outgoing.stopCallCount, 1);
    });

    test('velocidad/Skip Silence/volumen configurados antes se preservan en el motor entrante '
        'tras el swap', () async {
      await engine.setSpeed(1.25);
      await engine.setSkipSilenceEnabled(true);
      await engine.setVolume(0.4);

      await engine.crossfadeToLocalSource('/local/next.mp3', const Duration(milliseconds: 100));
      await engine.debugAwaitFadeSettled();

      final incoming = createdEngines[1];
      expect(incoming.setSpeedCallCount, greaterThanOrEqualTo(1),
          reason: 'el motor entrante debe recibir la velocidad canónica antes de sonar, no '
              'quedarse en el 1.0x por defecto del motor nativo');
      expect(incoming.lastSkipSilence, isTrue,
          reason: 'Skip Silence no debe apagarse solo en el motor que pasa a estar activo');
      // El volumen final del entrante (tras el ramp completo) debe llegar
      // al volumen canónico del usuario (0.4), no forzarse a 1.0.
      final incomingVolumes = volumeHistories[1];
      expect(incomingVolumes.last, closeTo(0.4, 0.001),
          reason: 'el swap no debe pisar el volumen que el usuario tenía puesto con un 1.0 fijo');
    });

    test('el motor viejo queda vivo e inactivo tras el swap (no se destruye, listo para reusarse)',
        () async {
      await engine.crossfadeToLocalSource('/local/next.mp3', const Duration(milliseconds: 100));
      await engine.debugAwaitFadeSettled();

      // Un segundo crossfade debe reusar la misma instancia vieja como
      // _standby en vez de crear una tercera.
      await engine.crossfadeToLocalSource('/local/third.mp3', const Duration(milliseconds: 100));
      await engine.debugAwaitFadeSettled();
      expect(createdEngines.length, 2, reason: 'el motor viejo se reutiliza, nunca se recrea');
    });

    test(
        'una segunda llamada a crossfadeToLocalSource mientras la primera sigue en curso (su ramp '
        'en background todavía corriendo) no deja ningún Future colgado (P0: bug real — el '
        'reproductor quedaba sin poder saltar)', () async {
      // La primera resuelve rápido (P1) — su ramp en background (300ms)
      // sigue corriendo cuando llega la segunda.
      await engine
          .crossfadeToLocalSource('/local/a.mp3', const Duration(milliseconds: 300))
          .timeout(const Duration(seconds: 2));

      await engine
          .crossfadeToLocalSource('/local/b.mp3', const Duration(milliseconds: 300))
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => throw TimeoutException(
                'la segunda llamada nunca resolvió — el reproductor habría quedado trabado'),
          );

      // Nunca se crea una tercera instancia por la superposición: la
      // primera llamada crea _standby (engine #2); la segunda lo reusa.
      expect(createdEngines.length, 2);

      // El settle final (del ramp de la SEGUNDA llamada, la única vigente)
      // también debe resolver sin colgarse — el de la primera ya se
      // completó de inmediato al llegar la segunda, sin esperar a que su
      // bucle lo notara solo.
      await engine.debugAwaitFadeSettled().timeout(
            const Duration(seconds: 2),
            onTimeout: () => throw TimeoutException('el Completer del fade quedó colgado'),
          );
    });

    // Bug real de pruebas manuales: "la barra de volumen empieza desde
    // abajo". La UI lee `state.engine.volume` para el slider; el ramp del
    // fade escribe volúmenes intermedios (arrancando en 0) en el motor que
    // acaba de pasar a ser el activo, y esas escrituras se reenviaban tal
    // cual.
    test('el volumen que el wrapper reporta hacia afuera es el canónico, no el del ramp interno',
        () async {
      await engine.setVolume(0.6);

      final reported = <double>[];
      engine.stateStream.listen((s) => reported.add(s.volume));

      await engine.crossfadeToLocalSource('/local/next.mp3', const Duration(milliseconds: 200));
      await engine.debugAwaitFadeSettled();
      await pumpEventQueue();

      expect(reported, isNotEmpty);
      for (final v in reported) {
        expect(v, closeTo(0.6, 0.0001),
            reason: 'ningún estado reenviado a la UI debe exponer el volumen intermedio del fade');
      }
      // El motor entrante SÍ recibió el ramp real (el fundido de verdad
      // ocurrió): lo que se oculta es solo el reporte hacia afuera.
      expect(volumeHistories[1].first, 0.0);
      expect(volumeHistories[1].last, closeTo(0.6, 0.0001));
    });

    test('una transición NORMAL a mitad del fade detiene el motor saliente y restaura el volumen '
        'canónico en el activo', () async {
      await engine.setVolume(0.8);
      await engine.crossfadeToLocalSource('/local/next.mp3', const Duration(seconds: 4));
      // Deja correr algunos pasos del ramp para que el entrante quede a
      // volumen parcial y el saliente todavía sonando.
      await Future.delayed(const Duration(milliseconds: 120));

      final outgoing = createdEngines[0];
      final incoming = createdEngines[1];
      final stopsBefore = outgoing.stopCallCount;

      await engine.setLocalSource('/local/manual_skip.mp3');
      await pumpEventQueue();

      expect(outgoing.stopCallCount, greaterThan(stopsBefore),
          reason: 'el motor saliente no puede quedarse reproduciendo su pista en paralelo con la '
              'transición nueva');
      expect(volumeHistories[1].last, closeTo(0.8, 0.0001),
          reason: 'la pista nueva no debe arrancar al volumen parcial donde se cortó el ramp');
      expect(incoming.lastLocalSourcePath, '/local/manual_skip.mp3');
    });

    test('con crossfade configurado, _standby se pre-crea al cargar un archivo local (la latencia '
        'de arranque del motor no se paga a mitad del fade)', () async {
      fadeDurationSetting = const Duration(seconds: 4);

      await engine.setLocalSource('/local/a.mp3');

      expect(createdEngines.length, 2,
          reason: 'con el setting activado conviene tener el segundo motor listo antes de cruzar');
      expect(createdEngines[1].setLocalSourceCallCount, 0,
          reason: 'pre-crear no debe cargar nada todavía en el motor de reserva');
    });

    test('dispose() a mitad de un fade no deja timers corriendo ni futures pendientes', () async {
      unawaited(engine.crossfadeToLocalSource('/local/next.mp3', const Duration(seconds: 4)));
      // Deja que arranque el ramp en background sin esperar a que termine.
      await Future.delayed(const Duration(milliseconds: 20));

      final settled = engine.debugAwaitFadeSettled().timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw TimeoutException('el Completer del fade quedó colgado tras dispose()'),
      );

      engine.dispose();

      await settled;
    });

    test('microFadeOut() baja el volumen del motor activo a 0.0 y lo restaura tras detenerse', () async {
      await engine.setVolume(0.8);
      await engine.microFadeOut();
      expect(volumeHistories[0].contains(0.0), isTrue);
      expect(volumeHistories[0].last, closeTo(0.8, 0.0001));
    });
  });
}
