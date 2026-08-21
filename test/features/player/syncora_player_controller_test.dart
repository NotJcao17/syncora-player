import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/extraction/extraction_service.dart';
import 'package:syncora_player/core/extraction/models/extraction_request.dart';
import 'package:syncora_player/core/extraction/models/extraction_result.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/features/player/audio_engine/audio_engine_state.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/syncora_player_controller.dart';

class FakeAudioEngine implements AudioEngine {
  final _stateController = StreamController<AudioEngineState>.broadcast();
  final _completionController = StreamController<void>.broadcast();
  final _logStreamController = StreamController<String>.broadcast();

  AudioEngineState _state = AudioEngineState.initial;

  @override
  Stream<AudioEngineState> get stateStream => _stateController.stream;

  @override
  Stream<void> get completionStream => _completionController.stream;

  @override
  Stream<String> get logStream => _logStreamController.stream;

  void emitError() {
    emitState(_state.copyWith(processingState: AudioProcessingState.error));
  }

  @override
  Duration get position => _state.position;

  @override
  Duration get duration => _state.duration;

  void emitState(AudioEngineState newState) {
    _state = newState;
    _stateController.add(_state);
  }

  /// Mueve la posición "en vivo" del motor SIN emitir un tick por el stream
  /// — simula que el motor ya avanzó pero el controlador aún no procesó esa
  /// posición vía `_onEngineState` (el caso que ejercita la red de
  /// seguridad de `_onComplete`/`dispose`, que lee `_engine.position`
  /// directamente en vez de esperar al próximo tick).
  void setLivePositionOnly(Duration position) {
    _state = _state.copyWith(position: position);
  }

  void triggerCompletion() {
    _completionController.add(null);
  }

  String? lastUrl;
  int setUrlCallCount = 0;

  @override
  Future<void> setUrl(String url, {Map<String, String>? headers}) async {
    lastUrl = url;
    setUrlCallCount++;
    emitState(_state.copyWith(
      processingState: AudioProcessingState.ready,
      duration: const Duration(seconds: 180),
    ));
  }

  @override
  Future<void> setLocalSource(String path) async {
    emitState(_state.copyWith(
      processingState: AudioProcessingState.ready,
      duration: const Duration(seconds: 180),
    ));
  }


  @override
  Future<void> play() async {
    emitState(_state.copyWith(playing: true));
  }

  @override
  Future<void> pause() async {
    emitState(_state.copyWith(playing: false));
  }

  @override
  Future<void> stop() async {
    emitState(_state.copyWith(
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
  }

  @override
  Future<void> seek(Duration position) async {
    emitState(_state.copyWith(position: position));
  }

  @override
  Future<void> setSpeed(double speed) async {
    emitState(_state.copyWith(speed: speed));
  }

  @override
  Future<void> setVolume(double volume) async {
    emitState(_state.copyWith(volume: volume));
  }

  @override
  Future<void> setSkipSilenceEnabled(bool enabled) async {}

  @override
  void dispose() {
    _stateController.close();
    _completionController.close();
    _logStreamController.close();
  }
}

class TestableExtractionService implements ExtractionService {
  final StreamController<String> _logController = StreamController<String>.broadcast();
  int extractCount = 0;
  ExtractionError? forcedError;

  // Permite retener la resolución de un videoId concreto hasta que el test
  // la complete a mano — reproduce a voluntad la carrera de "extracción
  // vieja y lenta resuelve después de que el usuario ya cambió de pista".
  final Map<String, Completer<ExtractionResult>> _held = {};

  Completer<ExtractionResult> holdResolution(String videoId) {
    final completer = Completer<ExtractionResult>();
    _held[videoId] = completer;
    return completer;
  }

  @override
  Stream<String> get onLogMessage => _logController.stream;

  @override
  Future<ExtractionResult> extractUrl(
    String videoId, {
    String? trackTitle,
    String? trackArtist,
    int? durationSeconds,
    ExtractionPriority priority = ExtractionPriority.streaming,
  }) async {
    extractCount++;
    final held = _held.remove(videoId);
    if (held != null) {
      return held.future;
    }
    if (forcedError != null) {
      return ExtractionFailure(
        requestId: 'req_$extractCount',
        error: forcedError!,
        message: 'Forced error $forcedError',
      );
    }

    if (videoId == 'not_found_track') {
      return ExtractionFailure(
        requestId: 'req_$extractCount',
        error: ExtractionError.notFound,
        message: 'Track not found',
      );
    }

    return ExtractionSuccess(
      requestId: 'req_$extractCount',
      streamUrl: 'https://example.com/audio_$videoId.mp3',
      headers: const {},
    );
  }

  @override
  void resetEngine() {}

  @override
  void dispose() {
    _logController.close();
  }
}

void main() {
  group('SyncoraPlayerController Tests', () {
    late FakeAudioEngine engine;
    late TestableExtractionService extractionService;
    late SyncoraPlayerController controller;

    final testTracks = [
      const SyncoraTrack(id: 'track1', title: 'Track 1'),
      const SyncoraTrack(id: 'track2', title: 'Track 2'),
      const SyncoraTrack(id: 'track3', title: 'Track 3'),
    ];

    setUp(() {
      engine = FakeAudioEngine();
      extractionService = TestableExtractionService();
      controller = SyncoraPlayerController(
        engine: engine,
        extractionService: extractionService,
      );
      controller.init();
    });

    tearDown(() {
      controller.dispose();
    });

    test('1. Estado inicial es idle (no playing)', () {
      expect(controller.state.engine.playing, isFalse);
      expect(controller.state.queue, isEmpty);
      expect(controller.state.currentIndex, -1);
      expect(controller.state.currentTrack, isNull);
    });

    test('2. play() -> estado transiciona a playing', () async {
      await controller.setQueue(testTracks, autoplay: false);
      expect(controller.state.engine.playing, isFalse);

      await controller.play();
      expect(controller.state.engine.playing, isTrue);
    });

    test('3. pause() -> estado transiciona a paused', () async {
      await controller.setQueue(testTracks, autoplay: true);
      expect(controller.state.engine.playing, isTrue);

      await controller.pause();
      expect(controller.state.engine.playing, isFalse);
    });

    test('4. Error rateLimited persistente -> exactamente 1 reintento -> pausado (guard 403)', () async {
      extractionService.forcedError = ExtractionError.rateLimited;

      await controller.setQueue([testTracks[0]], autoplay: true);

      // Intento 1 + 1 reintento = 2 llamadas a extractUrl
      expect(extractionService.extractCount, 2);
      expect(controller.state.lastError, ExtractionError.rateLimited);
      expect(controller.state.engine.playing, isFalse);
    });

    test('5. Error notFound -> auto-skip inmediato (sin reintento)', () async {
      final queueWithBadTrack = [
        const SyncoraTrack(id: 'not_found_track', title: 'Bad Track'),
        const SyncoraTrack(id: 'track2', title: 'Track 2'),
      ];

      await controller.setQueue(queueWithBadTrack, autoplay: true);

      // notFound no debe reintentar la pista 1, debe hacer auto-skip a pista 2
      expect(controller.state.currentIndex, 1);
      expect(controller.state.currentTrack?.id, 'track2');
    });

    test('6. skipToNext() en cola de 3 -> currentIndex avanza', () async {
      await controller.setQueue(testTracks, autoplay: true);
      expect(controller.state.currentIndex, 0);

      await controller.skipToNext();
      expect(controller.state.currentIndex, 1);

      await controller.skipToNext();
      expect(controller.state.currentIndex, 2);
    });

    test('7. Repeat one -> al completarse, vuelve a la misma pista', () async {
      await controller.setQueue(testTracks, autoplay: true);
      controller.setRepeatMode(SyncoraRepeatMode.one);

      expect(controller.state.currentIndex, 0);

      // Simular evento de finalización del engine
      engine.triggerCompletion();
      await pumpEventQueue();

      expect(controller.state.currentIndex, 0);
      expect(controller.state.engine.playing, isTrue);
    });

    test(
        '8. Extracción vieja y lenta no pisa el motor tras un cambio de pista '
        'posterior (guard de generación, ver bug reportado en Fase C)', () async {
      await controller.setQueue(testTracks, autoplay: false);

      // track1 empieza a resolverse pero se queda "colgada" a propósito —
      // simula una extracción de Fase C que tarda mucho (varios candidatos,
      // varios clientes) porque la pista no tiene un match bueno y fácil.
      final held = extractionService.holdResolution('track1');
      final firstPlay = controller.playIndex(0);
      await pumpEventQueue();

      // Mientras la extracción de track1 sigue pendiente, el usuario cambia
      // a track2 — esta sí resuelve de inmediato.
      await controller.playIndex(1);
      expect(controller.state.currentIndex, 1);
      expect(engine.lastUrl, contains('track2'));
      final urlCountAfterTrack2 = engine.setUrlCallCount;

      // Ahora, tarde, la extracción huérfana de track1 por fin resuelve con
      // éxito. Sin el guard de generación, esto pisaría el motor con la URL
      // de track1 aunque el usuario ya esté en track2.
      held.complete(ExtractionSuccess(
        requestId: 'stale_req',
        streamUrl: 'https://example.com/audio_track1.mp3',
        headers: const {},
      ));
      await firstPlay;
      await pumpEventQueue();

      expect(controller.state.currentIndex, 1, reason: 'no debe volver a track1');
      expect(engine.lastUrl, contains('track2'), reason: 'el motor no debe recibir la URL vieja de track1');
      expect(engine.setUrlCallCount, urlCountAfterTrack2, reason: 'la resolución obsoleta no debe llamar a setUrl de nuevo');
    });

    test(
        '9. AudioProcessingState.error del motor dispara auto-skip en vez de trabarse '
        '(antes solo se manejaba ExtractionFailure, no un fallo del motor nativo)', () async {
      await controller.setQueue(testTracks, autoplay: true);
      expect(controller.state.currentIndex, 0);

      engine.emitError();
      await pumpEventQueue();

      // skipToNext() limpia lastError al avanzar (clearError: true) — mismo
      // comportamiento ya existente para ExtractionError.notFound, el error
      // es transitorio por diseño. Lo que importa aquí es que sí avanzó en
      // vez de quedarse trabado en processingState.error para siempre.
      expect(controller.state.currentIndex, 1, reason: 'debe saltar a la siguiente pista, no quedarse trabado');
    });
  });

  // Fase 7.0.2 / 7.0.5: registro de historial de escucha (umbral D-16).
  group('SyncoraPlayerController — registro de historial de escucha (7.0.2)', () {
    late FakeAudioEngine engine;
    late TestableExtractionService extractionService;
    late SyncoraPlayerController controller;
    late SyncoraDatabase db;

    setUp(() {
      engine = FakeAudioEngine();
      extractionService = TestableExtractionService();
      db = SyncoraDatabase(NativeDatabase.memory());
      controller = SyncoraPlayerController(
        engine: engine,
        extractionService: extractionService,
        listeningHistoryDao: db.listeningHistoryDao,
      );
      controller.init();
    });

    tearDown(() async {
      controller.dispose();
      await db.close();
    });

    /// Simula que el motor reporta un avance natural de posición de 1s por
    /// tick (como haría el positionStream real de just_audio/media_kit)
    /// mientras reproduce. `pumpEventQueue()` deja que el StreamController
    /// del engine notifique al controlador entre cada tick.
    Future<void> playSeconds(int fromInclusive, int toInclusive) async {
      for (var s = fromInclusive; s <= toInclusive; s++) {
        engine.emitState(controller.state.engine.copyWith(
          playing: true,
          position: Duration(seconds: s),
        ));
        await pumpEventQueue();
      }
    }

    test('justo por debajo del umbral absoluto (29s de 200s) -> no registra', () async {
      final track = SyncoraTrack(id: 't1', title: 'Larga', duration: const Duration(seconds: 200));
      await controller.setQueue([track], autoplay: true);

      await playSeconds(1, 29);

      final history = await db.listeningHistoryDao.getRecentHistory();
      expect(history, isEmpty);
    });

    test('justo en/por encima del umbral absoluto (30s de 200s) -> registra', () async {
      final track = SyncoraTrack(id: 't1', title: 'Larga', duration: const Duration(seconds: 200));
      await controller.setQueue([track], autoplay: true);

      await playSeconds(1, 30);

      final history = await db.listeningHistoryDao.getRecentHistory();
      expect(history.length, 1);
      expect(history.first.trackId, track.deezerId);
    });

    test('pista corta (<60s): manda la regla del 50% en vez de los 30s', () async {
      // 40s de duración -> mitad = 20s, menor que el mínimo absoluto de 30s.
      final track = SyncoraTrack(id: 't1', title: 'Corta', duration: const Duration(seconds: 40));
      await controller.setQueue([track], autoplay: true);

      await playSeconds(1, 19);
      var history = await db.listeningHistoryDao.getRecentHistory();
      expect(history, isEmpty, reason: '19s < 20s (50% de 40s): no debe registrar todavía');

      await playSeconds(20, 20);
      history = await db.listeningHistoryDao.getRecentHistory();
      expect(history.length, 1, reason: '20s alcanza el 50% de 40s: debe registrar');
    });

    test('un seek manual hacia adelante no infla el tiempo acumulado', () async {
      final track = SyncoraTrack(id: 't1', title: 'Larga', duration: const Duration(seconds: 200));
      await controller.setQueue([track], autoplay: true);

      // 10s reproducidos de forma natural.
      await playSeconds(1, 10);

      // Seek manual grande hacia adelante: 10s -> 190s. Si esto se contara
      // como tiempo escuchado (180s) superaría el umbral de sobra.
      engine.emitState(controller.state.engine.copyWith(
        playing: true,
        position: const Duration(seconds: 190),
      ));
      await pumpEventQueue();

      var history = await db.listeningHistoryDao.getRecentHistory();
      expect(history, isEmpty, reason: 'el salto del seek no debe contarse como tiempo escuchado');

      // 19s más de reproducción natural desde la nueva posición (10 + 19 = 29s reales).
      await playSeconds(191, 209);
      history = await db.listeningHistoryDao.getRecentHistory();
      expect(history, isEmpty, reason: 'acumulado real = 29s, todavía bajo el umbral de 30s');

      // 1s más: acumulado real = 30s -> cruza el umbral.
      await playSeconds(210, 210);
      history = await db.listeningHistoryDao.getRecentHistory();
      expect(history.length, 1);
    });

    test('no cuenta dos veces si el usuario retrocede (seek hacia atrás) dentro de la misma pista',
        () async {
      final track = SyncoraTrack(id: 't1', title: 'Larga', duration: const Duration(seconds: 200));
      await controller.setQueue([track], autoplay: true);

      await playSeconds(1, 30); // cruza el umbral y registra
      var history = await db.listeningHistoryDao.getRecentHistory();
      expect(history.length, 1);

      // El usuario retrocede y vuelve a escuchar un tramo ya sonado.
      engine.emitState(controller.state.engine.copyWith(
        playing: true,
        position: const Duration(seconds: 5),
      ));
      await pumpEventQueue();
      await playSeconds(6, 25);

      history = await db.listeningHistoryDao.getRecentHistory();
      expect(history.length, 1, reason: 'la misma instancia de reproducción no debe registrarse dos veces');
    });

    test('cambiar de pista antes de cruzar el umbral no registra esa instancia', () async {
      final track1 = SyncoraTrack(id: 't1', title: 'Uno', duration: const Duration(seconds: 200));
      final track2 = SyncoraTrack(id: 't2', title: 'Dos', duration: const Duration(seconds: 200));
      await controller.setQueue([track1, track2], autoplay: true);

      await playSeconds(1, 10); // solo 10s, bajo el umbral de 30s

      await controller.skipToNext();
      await pumpEventQueue();

      final history = await db.listeningHistoryDao.getRecentHistory();
      expect(history, isEmpty, reason: 'la pista 1 nunca cruzó el umbral antes del skip');
      expect(controller.state.currentTrack?.id, 't2');
    });

    test('completar la pista naturalmente dispara el registro', () async {
      // 10s de duración -> umbral = 5s (mitad, menor que 30s).
      final track = SyncoraTrack(id: 't1', title: 'Corta', duration: const Duration(seconds: 10));
      await controller.setQueue([track], autoplay: true);

      await playSeconds(1, 10);
      engine.triggerCompletion();
      await pumpEventQueue();

      final history = await db.listeningHistoryDao.getRecentHistory();
      expect(history.length, 1);
    });

    test('pausar y reanudar no pierde el progreso acumulado ni cuenta tiempo en pausa', () async {
      final track = SyncoraTrack(id: 't1', title: 'Larga', duration: const Duration(seconds: 200));
      await controller.setQueue([track], autoplay: true);

      await playSeconds(1, 15); // 15s acumulados

      // Pausa: no debe sumar tiempo aunque "pase tiempo" mientras está pausado.
      engine.emitState(controller.state.engine.copyWith(playing: false));
      await pumpEventQueue();

      // Reanuda desde la misma posición (15s) y sigue sumando desde ahí.
      await playSeconds(16, 29);
      var history = await db.listeningHistoryDao.getRecentHistory();
      expect(history, isEmpty, reason: '15 + 14 = 29s, todavía bajo el umbral de 30s');

      await playSeconds(30, 30);
      history = await db.listeningHistoryDao.getRecentHistory();
      expect(history.length, 1, reason: 'se conservó el progreso previo a la pausa: 30s en total');
    });

    // Regresión (revisión de código de Fase 7.0): cada una de estas cubre un
    // camino que reinicia/repite la pista actual SIN pasar por
    // `_beginListenTracking`, o que trataba una vuelta nueva como
    // continuación de la anterior.
    test('repeat-one: cada vuelta completa se registra por separado, no solo la primera', () async {
      // 10s de duración -> umbral = 5s (mitad, menor que 30s).
      final track = SyncoraTrack(id: 't1', title: 'Corta', duration: const Duration(seconds: 10));
      await controller.setQueue([track], autoplay: true);
      controller.setRepeatMode(SyncoraRepeatMode.one);

      await playSeconds(1, 10);
      engine.triggerCompletion(); // primera vuelta: cruza el umbral y hace seek(0)+play()
      await pumpEventQueue();

      var history = await db.listeningHistoryDao.getRecentHistory();
      expect(history.length, 1, reason: 'la primera vuelta debe registrarse');

      await playSeconds(1, 10); // segunda vuelta completa, desde 0 otra vez
      engine.triggerCompletion();
      await pumpEventQueue();

      history = await db.listeningHistoryDao.getRecentHistory();
      expect(history.length, 2,
          reason: 'una segunda vuelta completa en repeat-one debe registrarse también, no perderse');
    });

    test('reiniciar la pista actual con "anterior" (>3s) exige un nuevo umbral completo, no funde ambos intentos',
        () async {
      final track = SyncoraTrack(id: 't1', title: 'Larga', duration: const Duration(seconds: 200));
      await controller.setQueue([track], autoplay: true);

      await playSeconds(1, 20); // 20s, bajo el umbral de 30s

      await controller.skipToPrevious(); // posición > 3s, un solo tap -> reinicia la pista actual
      await pumpEventQueue();
      engine.emitState(controller.state.engine.copyWith(playing: true, position: Duration.zero));
      await pumpEventQueue();

      var history = await db.listeningHistoryDao.getRecentHistory();
      expect(history, isEmpty, reason: 'el reinicio no debe heredar los 20s previos como si fueran continuos');

      await playSeconds(1, 29);
      history = await db.listeningHistoryDao.getRecentHistory();
      expect(history, isEmpty, reason: 'tras el reinicio hacen falta 30s nuevos completos, no 10s (30-20)');

      await playSeconds(30, 30);
      history = await db.listeningHistoryDao.getRecentHistory();
      expect(history.length, 1, reason: 'se registra una sola vez, con el acumulado post-reinicio');
    });

    test('cola de 1 pista en repeat-all: dos pasadas parciales no se funden en una sola escucha', () async {
      final track = SyncoraTrack(id: 't1', title: 'Larga', duration: const Duration(seconds: 200));
      await controller.setQueue([track], autoplay: true);
      controller.setRepeatMode(SyncoraRepeatMode.all);

      await playSeconds(1, 16); // primera pasada: 16s, bajo el umbral de 30s
      await controller.skipToNext(); // cola de 1 pista + repeat-all -> vuelve al índice 0
      await pumpEventQueue();

      var history = await db.listeningHistoryDao.getRecentHistory();
      expect(history, isEmpty, reason: 'ninguna pasada individual llegó a 16s+16s=32s de forma continua');

      // El fake no resetea `position` solo por cargar una fuente nueva (a
      // diferencia de un motor real); se simula aquí el tick de posición=0
      // con el que arrancaría la segunda pasada.
      engine.emitState(controller.state.engine.copyWith(playing: true, position: Duration.zero));
      await pumpEventQueue();

      await playSeconds(1, 16); // segunda pasada: otros 16s desde cero
      history = await db.listeningHistoryDao.getRecentHistory();
      expect(history, isEmpty,
          reason: 'con el fix, cada pasada reinicia el acumulado: 16s de la segunda pasada, no 32s fundidos');

      await playSeconds(17, 30);
      history = await db.listeningHistoryDao.getRecentHistory();
      expect(history.length, 1, reason: 'la segunda pasada por sí sola sí alcanza los 30s y se registra');
    });

    test('red de seguridad de _onComplete: captura la posición en vivo aunque el último tick esté desactualizado',
        () async {
      // 10s de duración -> umbral = 5s.
      final track = SyncoraTrack(id: 't1', title: 'Corta', duration: const Duration(seconds: 10));
      await controller.setQueue([track], autoplay: true);

      // Ticks reales hasta 3s (bajo el umbral de 5s).
      await playSeconds(1, 3);
      var history = await db.listeningHistoryDao.getRecentHistory();
      expect(history, isEmpty);

      // El motor ya llegó a 5s (cruzando el umbral) pero no se emitió un
      // tick de posición para eso antes de la finalización -- exactamente
      // el caso que la red de seguridad debe cubrir. El salto (3s -> 5s) se
      // mantiene dentro de `_maxNaturalPositionJump` a propósito: esto NO es
      // un seek, es la brecha normal entre el último tick y la finalización.
      engine.setLivePositionOnly(const Duration(seconds: 5));
      engine.triggerCompletion();
      await pumpEventQueue();

      history = await db.listeningHistoryDao.getRecentHistory();
      expect(history.length, 1,
          reason: 'la red de seguridad debe leer la posición en vivo del motor, no la del último tick procesado');
    });
  });
}
