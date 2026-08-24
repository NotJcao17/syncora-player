import 'dart:async';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/extraction/extraction_service.dart';
import 'package:syncora_player/core/extraction/models/extraction_request.dart';
import 'package:syncora_player/core/extraction/models/extraction_result.dart';
import 'package:syncora_player/data/apis/deezer_api.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/features/player/audio_engine/audio_engine_state.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/radio/radio_service.dart';
import 'package:syncora_player/features/player/session/player_session_storage.dart';
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

  // Fase 7.D: tracking de llamadas para verificar delegación exacta desde
  // `CrossfadeAudioEngine` (ver crossfade_audio_engine_test.dart) — mismo
  // patrón que `lastUrl`/`setUrlCallCount` de arriba, para `setLocalSource`.
  String? lastLocalSourcePath;
  int setLocalSourceCallCount = 0;

  @override
  Future<void> setLocalSource(String path) async {
    lastLocalSourcePath = path;
    setLocalSourceCallCount++;
    emitState(_state.copyWith(
      processingState: AudioProcessingState.ready,
      duration: const Duration(seconds: 180),
    ));
  }

  int playCallCount = 0;

  @override
  Future<void> play() async {
    playCallCount++;
    emitState(_state.copyWith(playing: true));
  }

  // Revisión de código: `expect(engine.playing, isFalse)` por sí solo pasa
  // trivialmente si nada llegó a reproducirse nunca (el estado inicial ya
  // es `playing: false`) — no distingue "se pausó de verdad" de "nunca sonó
  // nada". Contar llamadas reales a pause() permite verificar que el guard
  // 403/H-6 y el guard de cascada (7.C.3) de verdad invocan al motor.
  int pauseCallCount = 0;

  @override
  Future<void> pause() async {
    pauseCallCount++;
    emitState(_state.copyWith(playing: false));
  }

  int stopCallCount = 0;

  @override
  Future<void> stop() async {
    stopCallCount++;
    emitState(_state.copyWith(
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
  }

  int microFadeOutCallCount = 0;

  @override
  Future<void> microFadeOut() async {
    microFadeOutCallCount++;
  }

  @override
  Future<void> seek(Duration position) async {
    emitState(_state.copyWith(position: position));
  }

  int setSpeedCallCount = 0;

  @override
  Future<void> setSpeed(double speed) async {
    setSpeedCallCount++;
    emitState(_state.copyWith(speed: speed));
  }

  @override
  Future<void> setVolume(double volume) async {
    emitState(_state.copyWith(volume: volume));
  }

  // Fase 7.D: tracking para verificar que `CrossfadeAudioEngine` propaga
  // Skip Silence al motor entrante (bug corregido en revisión de código:
  // `_standby` nunca lo recibía mientras dormía).
  bool? lastSkipSilence;
  int setSkipSilenceCallCount = 0;

  @override
  Future<void> setSkipSilenceEnabled(bool enabled) async {
    lastSkipSilence = enabled;
    setSkipSilenceCallCount++;
  }

  // Fase 7.D: stub sin fade real — solo registra la llamada (path/duration)
  // para que los tests de crossfade en el controlador puedan verificar que
  // se invocó en vez de la secuencia normal de stop+load+play. El fade de
  // verdad se prueba contra `CrossfadeAudioEngine` (que sí envuelve motores
  // reales/fake) en su propio archivo de test.
  String? lastCrossfadePath;
  Duration? lastCrossfadeDuration;
  int crossfadeCallCount = 0;

  @override
  Future<void> crossfadeToLocalSource(String path, Duration duration) async {
    crossfadeCallCount++;
    lastCrossfadePath = path;
    lastCrossfadeDuration = duration;
    emitState(_state.copyWith(
      processingState: AudioProcessingState.ready,
      duration: const Duration(seconds: 180),
      playing: true,
    ));
  }

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
  // Permite marcar ids específicos como "no encontrados" (a diferencia de
  // `forcedError`, que aplica a TODOS los ids) — usado para probar cascadas
  // de auto-skip de varios pasos sin que la pista "buena" también falle.
  final Set<String> notFoundIds = {};

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

    if (videoId == 'not_found_track' || notFoundIds.contains(videoId)) {
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

/// Doble de [PlayerSessionStorage] (Fase 7.F.2): reproduce, sin tocar el
/// filesystem, el único estado real por el que `currentTrack` puede ser
/// null con `manualQueue` no vacía -- una sesión restaurada tras un
/// `setQueue([])` guardado (ver el comentario de `_restoreSession` en
/// `syncora_player_controller.dart`). `PlayerSessionStorage` no es una
/// interfaz, pero sus métodos son subclasseables.
class _FakeRestoredSessionStorage extends PlayerSessionStorage {
  final List<SyncoraTrack> manualQueue;
  _FakeRestoredSessionStorage({required this.manualQueue});

  @override
  Future<PlayerSessionData?> loadSession() async {
    return PlayerSessionData(
      currentTrack: null,
      currentOrigin: null,
      manualQueue: manualQueue,
      autoQueue: const [],
      originalContextTracks: const [],
      history: const [],
      positionSeconds: 0,
      repeatMode: SyncoraRepeatMode.off,
      shuffle: false,
    );
  }

  @override
  Future<void> saveSession({
    required SyncoraTrack? currentTrack,
    required QueueOrigin? currentOrigin,
    required List<SyncoraTrack> manualQueue,
    required List<SyncoraTrack> autoQueue,
    required List<SyncoraTrack> originalContextTracks,
    required List<HistoryEntry> history,
    required int positionSeconds,
    required SyncoraRepeatMode repeatMode,
    required bool shuffle,
    String? activeContextId,
  }) async {}
}

/// Fake de [RadioService] (Fase 7.B): sobreescribe [generateBatch] para no
/// hacer ninguna llamada de red real. `RadioService` es una clase concreta
/// (no una interfaz), así que extenderla y sobreescribir el único método
/// con I/O es el equivalente directo a `FakeAudioEngine`/
/// `TestableExtractionService` de este mismo archivo.
class FakeRadioService extends RadioService {
  FakeRadioService({this.nextBatch = const []});

  /// Lote que devolverá `generateBatch` la próxima vez que se llame (salvo
  /// que haya una resolución retenida vía [holdNextBatch]).
  List<SyncoraTrack> nextBatch;
  int callCount = 0;
  List<SyncoraTrack>? lastContextTracks;
  Set<String>? lastExcludeIds;
  Completer<List<SyncoraTrack>>? _held;

  /// Retiene la resolución de la próxima llamada a `generateBatch` hasta que
  /// el test complete el `Completer` devuelto — reproduce a voluntad la
  /// carrera de "el lote llega tarde, después de que el usuario ya cambió
  /// de contexto" (mismo patrón que `TestableExtractionService.holdResolution`
  /// en este archivo).
  Completer<List<SyncoraTrack>> holdNextBatch() {
    final completer = Completer<List<SyncoraTrack>>();
    _held = completer;
    return completer;
  }

  @override
  Future<List<SyncoraTrack>> generateBatch({
    required List<SyncoraTrack> contextTracks,
    required Set<String> excludeIds,
  }) async {
    callCount++;
    lastContextTracks = contextTracks;
    lastExcludeIds = excludeIds;
    final held = _held;
    if (held != null) {
      _held = null;
      return held.future;
    }
    return nextBatch;
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
      expect(controller.state.manualQueue, isEmpty);
      expect(controller.state.autoQueue, isEmpty);
      expect(controller.state.currentTrack, isNull);
      expect(controller.state.currentOrigin, isNull);
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
      expect(controller.state.currentTrack?.id, 'track2');
      expect(controller.state.currentOrigin, QueueOrigin.auto);
    });

    test('6. skipToNext() en cola de 3 -> avanza consumiendo la automática en orden', () async {
      await controller.setQueue(testTracks, autoplay: true);
      expect(controller.state.currentTrack?.id, 'track1');

      await controller.skipToNext();
      expect(controller.state.currentTrack?.id, 'track2');

      await controller.skipToNext();
      expect(controller.state.currentTrack?.id, 'track3');
    });

    test('7. Repeat one -> al completarse, vuelve a la misma pista', () async {
      await controller.setQueue(testTracks, autoplay: true);
      controller.setRepeatMode(SyncoraRepeatMode.one);

      expect(controller.state.currentTrack?.id, 'track1');

      // Simular evento de finalización del engine
      engine.triggerCompletion();
      await pumpEventQueue();

      expect(controller.state.currentTrack?.id, 'track1');
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
      final firstPlay = controller.playCurrent();
      await pumpEventQueue();

      // Mientras la extracción de track1 sigue pendiente, el usuario cambia
      // a track2 (primera de la automática) — esta sí resuelve de inmediato.
      await controller.playFromQueue(QueueOrigin.auto, 0);
      expect(controller.state.currentTrack?.id, 'track2');
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

      expect(controller.state.currentTrack?.id, 'track2', reason: 'no debe volver a track1');
      expect(engine.lastUrl, contains('track2'), reason: 'el motor no debe recibir la URL vieja de track1');
      expect(engine.setUrlCallCount, urlCountAfterTrack2, reason: 'la resolución obsoleta no debe llamar a setUrl de nuevo');
    });

    test(
        '9. AudioProcessingState.error del motor dispara auto-skip en vez de trabarse '
        '(antes solo se manejaba ExtractionFailure, no un fallo del motor nativo)', () async {
      await controller.setQueue(testTracks, autoplay: true);
      expect(controller.state.currentTrack?.id, 'track1');

      engine.emitError();
      await pumpEventQueue();

      // skipToNext() limpia lastError al avanzar (clearError: true) — mismo
      // comportamiento ya existente para ExtractionError.notFound, el error
      // es transitorio por diseño. Lo que importa aquí es que sí avanzó en
      // vez de quedarse trabado en processingState.error para siempre.
      expect(controller.state.currentTrack?.id, 'track2', reason: 'debe saltar a la siguiente pista, no quedarse trabado');
    });

    test(
        '10. Dos fallos notFound consecutivos encadenan hasta una pista reproducible '
        '(P1.8: el guard real de _isTransitioning no debe bloquear la cascada interna)', () async {
      final chain = [
        const SyncoraTrack(id: 'bad1', title: 'Bad 1'),
        const SyncoraTrack(id: 'bad2', title: 'Bad 2'),
        const SyncoraTrack(id: 'good', title: 'Good'),
      ];
      extractionService.notFoundIds.addAll(['bad1', 'bad2']);

      await controller.setQueue(chain, autoplay: true);

      // Si el guard hubiera bloqueado la cascada interna (bug que introduciría
      // una implementación ingenua de "if (_isTransitioning) return;" aplicada
      // también a las llamadas anidadas de _handleExtractionError), esto se
      // habría quedado trabado en bad2 o incluso en bad1.
      expect(controller.state.currentTrack?.id, 'good',
          reason: 'debe encadenar el auto-skip por dos fallos seguidos sin trabarse en el primero');
      expect(controller.state.engine.playing, isTrue);
    });

    test('11. Dos llamadas concurrentes a skipToNext() no avanzan dos veces en paralelo (P1.8: guard real)',
        () async {
      await controller.setQueue(testTracks, autoplay: true); // current=track1, autoQueue=[track2,track3]

      final first = controller.skipToNext(); // dispara la transición (sin await todavía)
      final second = controller.skipToNext(); // debe verse bloqueada de inmediato por el guard

      await first;
      await second;

      expect(controller.state.currentTrack?.id, 'track2',
          reason: 'solo UN avance debe haber ocurrido, no dos (llegar a track3 indicaría que el guard no bloqueó nada)');
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
      await controller.skipToNext(); // cola de 1 pista + repeat-all -> vuelve a la misma pista
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

  // Fase 7.A: modelo de cola dual (manual + automática). Ver
  // docs/plan_fase_7.md decisiones D-1/D-2/D-3.
  group('SyncoraPlayerController — cola dual (Fase 7.A)', () {
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

    test('reorderQueue reordena solo dentro de la sección indicada, sin afectar la otra', () async {
      await controller.setQueue(testTracks, autoplay: false); // current=track1, autoQueue=[track2,track3]
      controller.addToQueue(const SyncoraTrack(id: 'm1', title: 'Manual 1'));
      controller.addToQueue(const SyncoraTrack(id: 'm2', title: 'Manual 2'));
      controller.addToQueue(const SyncoraTrack(id: 'm3', title: 'Manual 3'));

      controller.reorderQueue(QueueOrigin.manual, 0, 2); // mover m1 después de m2
      expect(controller.state.manualQueue.map((t) => t.id).toList(), ['m2', 'm1', 'm3']);
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['track2', 'track3'],
          reason: 'reordenar la manual no debe afectar la automática');

      controller.reorderQueue(QueueOrigin.auto, 1, 0); // mover track3 al frente de la automática
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['track3', 'track2']);
      expect(controller.state.manualQueue.map((t) => t.id).toList(), ['m2', 'm1', 'm3'],
          reason: 'reordenar la automática no debe afectar la manual');
    });

    test('agregar 2 pistas manuales seguidas mantiene orden FIFO (A luego B, D-2)', () async {
      // Con algo ya "actual" (setQueue), addToQueue no promueve nada — aísla
      // el comportamiento FIFO puro del P0.3 (promoción cuando no hay nada
      // sonando), cubierto en un test aparte más abajo.
      await controller.setQueue(testTracks, autoplay: false);
      controller.addToQueue(const SyncoraTrack(id: 'a', title: 'A'));
      controller.addToQueue(const SyncoraTrack(id: 'b', title: 'B'));
      expect(controller.state.manualQueue.map((t) => t.id).toList(), ['a', 'b']);
    });

    test('playNext inserta al frente de la manual, no al final', () async {
      await controller.setQueue(testTracks, autoplay: false);
      controller.addToQueue(const SyncoraTrack(id: 'a', title: 'A'));
      controller.playNext(const SyncoraTrack(id: 'urgent', title: 'Urgente'));
      expect(controller.state.manualQueue.map((t) => t.id).toList(), ['urgent', 'a']);
    });

    // P0.3: sin esto, agregar una pista a la cola manual cuando no hay nada
    // sonando la dejaba inalcanzable (nadie más que un skipToNext/anterior
    // la recuperaba, y no había nada de qué avanzar).
    test('addToQueue promueve la pista a currentTrack si no había nada sonando (P0.3)', () {
      expect(controller.state.currentTrack, isNull);
      controller.addToQueue(const SyncoraTrack(id: 'a', title: 'A'));
      expect(controller.state.currentTrack?.id, 'a');
      expect(controller.state.currentOrigin, QueueOrigin.manual);
      expect(controller.state.manualQueue, isEmpty, reason: 'la pista promovida sale de la cola manual');
      expect(controller.state.engine.playing, isFalse,
          reason: 'la promoción NO debe forzar autoplay — deja "listo, pausado"');
    });

    test('playNext promueve la pista a currentTrack si no había nada sonando (P0.3)', () {
      expect(controller.state.currentTrack, isNull);
      controller.playNext(const SyncoraTrack(id: 'urgent', title: 'Urgente'));
      expect(controller.state.currentTrack?.id, 'urgent');
      expect(controller.state.currentOrigin, QueueOrigin.manual);
      expect(controller.state.manualQueue, isEmpty);
      expect(controller.state.engine.playing, isFalse);
    });

    test('cambiar shuffle no toca manualQueue, solo reordena autoQueue', () async {
      await controller.setQueue(testTracks, autoplay: false);
      controller.addToQueue(const SyncoraTrack(id: 'manual1', title: 'Manual'));

      controller.setShuffle(true);

      expect(controller.state.manualQueue.map((t) => t.id).toList(), ['manual1']);
      expect(controller.state.shuffle, isTrue);
      expect(controller.state.autoQueue.map((t) => t.id).toSet(), {'track2', 'track3'},
          reason: 'shuffle solo reordena la automática, no debe perder ni ganar pistas');
    });

    test('setQueue (cambiar de playlist) no toca manualQueue, sí reemplaza autoQueue/originalContextTracks', () async {
      await controller.setQueue(testTracks, autoplay: false);
      controller.addToQueue(const SyncoraTrack(id: 'manual1', title: 'Manual'));

      final newTracks = [
        const SyncoraTrack(id: 'n1', title: 'N1'),
        const SyncoraTrack(id: 'n2', title: 'N2'),
      ];
      await controller.setQueue(newTracks, autoplay: false, activeContextId: 'playlist_new');

      expect(controller.state.manualQueue.map((t) => t.id).toList(), ['manual1'],
          reason: 'D-1: la manual sobrevive a cambios de contexto/playlist');
      expect(controller.state.currentTrack?.id, 'n1');
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['n2']);
      expect(controller.state.originalContextTracks.map((t) => t.id).toList(), ['n1', 'n2']);
    });

    test('"anterior" tras consumir una pista manual vuelve a esa pista manual, no a la automática', () async {
      await controller.setQueue(testTracks, autoplay: true); // current=track1, autoQueue=[track2,track3]
      controller.playNext(const SyncoraTrack(id: 'manual1', title: 'Manual'));

      await controller.skipToNext(); // D-1: manual precede -> current=manual1
      expect(controller.state.currentTrack?.id, 'manual1');
      expect(controller.state.currentOrigin, QueueOrigin.manual);

      await controller.skipToPrevious();
      expect(controller.state.currentTrack?.id, 'track1');
      expect(controller.state.currentOrigin, QueueOrigin.auto);
      expect(controller.state.manualQueue.map((t) => t.id).toList(), ['manual1'],
          reason: 'manual1 debe volver al frente de su propia cola de origen');
    });

    test('avanzar consume la pista de su cola de origen (se elimina)', () async {
      await controller.setQueue(testTracks, autoplay: true);
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['track2', 'track3']);

      await controller.skipToNext();
      expect(controller.state.currentTrack?.id, 'track2');
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['track3'],
          reason: 'track2 debe salir de autoQueue al consumirse');
    });

    test('la manual precede a la automática incluso si esta ya estaba "en curso" cuando se agregó la manual',
        () async {
      await controller.setQueue(testTracks, autoplay: true); // current=track1, autoQueue=[track2,track3]
      await controller.skipToNext(); // current=track2, autoQueue=[track3] — automática ya en curso

      controller.addToQueue(const SyncoraTrack(id: 'manual1', title: 'Manual'));

      await controller.skipToNext();
      expect(controller.state.currentTrack?.id, 'manual1', reason: 'D-1: manual siempre antes que automática');
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['track3'],
          reason: 'priorizar la manual no debe tocar la automática');
    });

    test('repeat-all regenera autoQueue desde originalContextTracks cuando ambas colas se agotan', () async {
      final twoTracks = [
        const SyncoraTrack(id: 'r1', title: 'R1'),
        const SyncoraTrack(id: 'r2', title: 'R2'),
      ];
      await controller.setQueue(twoTracks, autoplay: true);
      controller.setRepeatMode(SyncoraRepeatMode.all);

      await controller.skipToNext();
      expect(controller.state.currentTrack?.id, 'r2');
      expect(controller.state.autoQueue, isEmpty);

      await controller.skipToNext(); // ambas colas vacías -> regenerar desde originalContextTracks
      expect(controller.state.currentTrack?.id, 'r1');
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['r2']);
    });

    test('removeFromQueue no afecta currentTrack ni historial (la pista nunca sonó)', () async {
      await controller.setQueue(testTracks, autoplay: true);
      controller.addToQueue(const SyncoraTrack(id: 'm1', title: 'M1'));
      controller.addToQueue(const SyncoraTrack(id: 'm2', title: 'M2'));

      controller.removeFromQueue(QueueOrigin.manual, 0); // quita m1
      expect(controller.state.manualQueue.map((t) => t.id).toList(), ['m2']);
      expect(controller.state.currentTrack?.id, 'track1');
      expect(controller.state.history, isEmpty);
    });

    test('clearQueue vacía solo la cola manual, sin tocar autoQueue, currentTrack ni historial', () async {
      await controller.setQueue(testTracks, autoplay: true); // current=track1, autoQueue=[track2,track3]
      controller.addToQueue(const SyncoraTrack(id: 'm1', title: 'M1'));

      controller.clearQueue();

      expect(controller.state.manualQueue, isEmpty);
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['track2', 'track3']);
      expect(controller.state.currentTrack?.id, 'track1');
    });

    // D-1: la cola automática (lo que sigue del contexto/playlist activo)
    // nunca debe vaciarse por "Limpiar cola" -- solo lo agregado a mano.
    test('clearQueue no toca originalContextTracks: repeat-all sigue pudiendo regenerar la auto', () async {
      await controller.setQueue(testTracks, autoplay: true); // current=track1, autoQueue=[track2,track3]
      controller.setRepeatMode(SyncoraRepeatMode.all);

      controller.clearQueue();
      expect(controller.state.originalContextTracks, isNotEmpty);

      await controller.skipToNext();
      expect(controller.state.currentTrack?.id, 'track2',
          reason: 'la cola automática sigue intacta tras clearQueue, ajena a la manual');
    });

    test('playFromQueue descarta las pistas anteriores al índice (nunca sonaron, no van a historial)', () async {
      await controller.setQueue(testTracks, autoplay: true); // current=track1, autoQueue=[track2,track3]

      await controller.playFromQueue(QueueOrigin.auto, 1); // saltar directo a track3
      expect(controller.state.currentTrack?.id, 'track3');
      expect(controller.state.autoQueue, isEmpty, reason: 'track2 (anterior al índice) se descarta, no queda en cola');
      expect(controller.state.history.map((h) => h.track.id).toList(), ['track1'],
          reason: 'la pista que sí sonaba (track1) sí va al historial');
    });
  });

  group('SyncoraPlayerController — "Crear cola con IA" (Fase 7.F.2)', () {
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

    test('addAllToQueue agrega todas al final de la manual, en una sola mutación, respetando FIFO (D-2)',
        () async {
      await controller.setQueue(testTracks, autoplay: false); // current=track1
      controller.addToQueue(const SyncoraTrack(id: 'existing', title: 'Existing'));

      controller.addAllToQueue([
        const SyncoraTrack(id: 'ai1', title: 'AI 1'),
        const SyncoraTrack(id: 'ai2', title: 'AI 2'),
      ]);

      expect(controller.state.manualQueue.map((t) => t.id).toList(), ['existing', 'ai1', 'ai2']);
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['track2', 'track3'],
          reason: 'D-1: nunca toca la automática');
    });

    test('addAllToQueue con lista vacía es un no-op', () async {
      await controller.setQueue(testTracks, autoplay: false);
      controller.addAllToQueue(const []);
      expect(controller.state.manualQueue, isEmpty);
    });

    test('addAllToQueue promueve la primera a currentTrack si no había nada sonando', () {
      controller.addAllToQueue([
        const SyncoraTrack(id: 'a', title: 'A'),
        const SyncoraTrack(id: 'b', title: 'B'),
      ]);
      expect(controller.state.currentTrack?.id, 'a');
      expect(controller.state.manualQueue.map((t) => t.id).toList(), ['b']);
    });

    test('interleaveIntoAutoQueue reparte las sugerencias con paso adaptativo (D-9), sin tocar la manual',
        () async {
      final sixTracks = List.generate(6, (i) => SyncoraTrack(id: 'a$i', title: 'A$i'));
      await controller.setQueue(sixTracks, autoplay: false); // current=a0, autoQueue=[a1..a5] (5 pistas)
      controller.addToQueue(const SyncoraTrack(id: 'manual1', title: 'Manual'));

      controller.interleaveIntoAutoQueue([
        const SyncoraTrack(id: 'ai1', title: 'AI 1'),
        const SyncoraTrack(id: 'ai2', title: 'AI 2'),
      ]);

      // autoQueue previa: [a1,a2,a3,a4,a5] (5 pistas), 2 sugerencias -> paso
      // adaptativo = 5~/2 = 2 (no el fijo "cada 3" del plan original: con
      // paso fijo la 2da sugerencia quedaba pegada en bloque al final en
      // vez de repartida -- hallazgo de la revisión de 7.F.2). Se inserta
      // una sugerida cada 2 pistas automáticas, ambas quedan intercaladas.
      expect(controller.state.autoQueue.map((t) => t.id).toList(),
          ['a1', 'a2', 'ai1', 'a3', 'a4', 'ai2', 'a5']);
      expect(controller.state.manualQueue.map((t) => t.id).toList(), ['manual1'],
          reason: 'D-1: intercalar nunca toca la cola manual');
    });

    test(
        'interleaveIntoAutoQueue tras restaurar una sesión con currentTrack null y manualQueue no '
        'vacía NO promueve una pista manual a "sonando ahora" (D-1, hallazgo de revisión de 7.F.2)',
        () async {
      // Reproduce el estado documentado en `_restoreSession`
      // (`syncora_player_controller.dart`): una sesión restaurada puede
      // tener `manualQueue` no vacía con `currentTrack` null (ej. tras un
      // `setQueue([])` guardado). Antes del fix, el `_advance()` de
      // conveniencia de `interleaveIntoAutoQueue` (pensado para arrancar
      // algo si no había nada sonando) ignoraba ese caso y promovía la
      // primera pista de la cola MANUAL del usuario a "sonando ahora" como
      // efecto secundario de una operación de IA sobre la automática --
      // justo lo que D-1 prohíbe. `PlayerSessionStorage` no es mockeable
      // por interfaz (es una clase concreta que escribe a disco), pero sí
      // es subclasseable -- `_FakeRestoredSessionStorage` sobreescribe
      // `loadSession()` para reproducir exactamente ese estado sin tocar el
      // filesystem.
      final restoredController = SyncoraPlayerController(
        engine: FakeAudioEngine(),
        extractionService: TestableExtractionService(),
        sessionStorage: _FakeRestoredSessionStorage(
          manualQueue: const [SyncoraTrack(id: 'manual1', title: 'Manual')],
        ),
      );
      restoredController.init();
      await pumpEventQueue(); // deja correr `_restoreSession()` (async, no-await desde `init()`)

      expect(restoredController.state.currentTrack, isNull,
          reason: 'precondición del escenario reportado: nada sonando tras restaurar');
      expect(restoredController.state.manualQueue.map((t) => t.id).toList(), ['manual1'],
          reason: 'precondición del escenario reportado: la manual restaurada no está vacía');

      restoredController.interleaveIntoAutoQueue([
        const SyncoraTrack(id: 'ai1', title: 'AI 1'),
      ]);

      expect(restoredController.state.manualQueue.map((t) => t.id).toList(), ['manual1'],
          reason: 'D-1: intercalar con IA nunca toca/consume la cola manual del usuario');
      expect(restoredController.state.currentTrack, isNull,
          reason: 'D-1: intercalar con IA no debe promover una pista manual a "sonando ahora"');

      restoredController.dispose();
    });

    test('interleaveIntoAutoQueue con autoQueue vacía anexa todas las sugerencias al final', () async {
      await controller.setQueue([testTracks.first], autoplay: false); // autoQueue queda vacía
      controller.interleaveIntoAutoQueue([
        const SyncoraTrack(id: 'ai1', title: 'AI 1'),
        const SyncoraTrack(id: 'ai2', title: 'AI 2'),
      ]);
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['ai1', 'ai2']);
    });

    test('interleaveIntoAutoQueue con lista vacía es un no-op', () async {
      await controller.setQueue(testTracks, autoplay: false);
      controller.interleaveIntoAutoQueue(const []);
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['track2', 'track3']);
    });

    test('interleaveIntoAutoQueue promueve la primera pista a currentTrack si no había nada sonando', () {
      controller.interleaveIntoAutoQueue([
        const SyncoraTrack(id: 'ai1', title: 'AI 1'),
        const SyncoraTrack(id: 'ai2', title: 'AI 2'),
      ]);
      expect(controller.state.currentTrack?.id, 'ai1');
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['ai2']);
    });
  });

  // Fase 7.A.7: adaptación de _skipSilently (salto offline, Fase 6) al
  // modelo dual — usa un Set<String> de ids de pista ya intentados en vez
  // de índices, ya que las colas ahora se acortan al consumirse.
  group('SyncoraPlayerController — salto silencioso offline (_skipSilently, Fase 7.A)', () {
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
        downloadedTrackDao: db.downloadedTrackDao,
        isConnectedGetter: () => false, // fuerza el camino offline en playCurrent()
      );
      controller.init();
    });

    tearDown(() async {
      controller.dispose();
      await db.close();
    });

    /// Inserta una fila "descargada" (downloadState == 2) para [track].
    Future<void> seedDownloaded(SyncoraTrack track) async {
      await db.downloadedTrackDao.insertOrUpdate(DownloadedTracksCompanion.insert(
        trackId: track.deezerId,
        artistId: 0,
        albumId: 0,
        title: track.title,
        artistName: track.artist,
        albumName: '',
        coverUrl: '',
        localAudioPath: '/fake/${track.id}.mp3',
        durationMs: 1000,
        downloadState: const Value(2),
      ));
    }

    test('no entra en loop infinito cuando ninguna pista está descargada (repeat off)', () async {
      final tracks = [
        const SyncoraTrack(id: 's1', title: 'S1'),
        const SyncoraTrack(id: 's2', title: 'S2'),
        const SyncoraTrack(id: 's3', title: 'S3'),
      ];

      await controller.setQueue(tracks, autoplay: true).timeout(const Duration(seconds: 5));
      await pumpEventQueue();

      expect(controller.state.engine.playing, isFalse);
      expect(controller.state.engine.processingState, AudioProcessingState.idle);
      // P0.2: sin nada reproducible en ninguna cola, currentTrack debe
      // quedar en null (no apuntando a una pista que nunca va a sonar).
      expect(controller.state.currentTrack, isNull);
    });

    test('con repeat-all, se detiene tras una vuelta completa sin encontrar nada descargado', () async {
      final tracks = [
        const SyncoraTrack(id: 'o1', title: 'O1'),
        const SyncoraTrack(id: 'o2', title: 'O2'),
      ];

      controller.setRepeatMode(SyncoraRepeatMode.all);
      await controller.setQueue(tracks, autoplay: true).timeout(const Duration(seconds: 5));
      await pumpEventQueue();

      expect(controller.state.engine.playing, isFalse);
      expect(controller.state.engine.processingState, AudioProcessingState.idle);
      expect(controller.state.currentTrack, isNull);
    });

    // P0.2: la versión anterior consumía la cola MANUAL con _advance() al
    // solo "probar" candidatos offline, violando D-1 (una pista manual sin
    // descargar quedaba eliminada para siempre). Ahora el bucle es de
    // solo-lectura: la manual debe seguir intacta salvo por la pista
    // realmente encontrada y reproducida (y lo que había antes de ella, que
    // sí se descarta correctamente porque nunca sonó).
    test('prioriza la cola manual sobre la automática y no la destruye al buscar un candidato descargado (P0.2)',
        () async {
      final auto1 = const SyncoraTrack(id: 'auto1', title: 'Auto 1');
      final auto2 = const SyncoraTrack(id: 'auto2', title: 'Auto 2');
      final manualNotDownloaded = const SyncoraTrack(id: 'manual_bad', title: 'Manual sin descargar');
      final manualDownloaded = const SyncoraTrack(id: 'manual_good', title: 'Manual descargada');

      await seedDownloaded(manualDownloaded);

      await controller.setQueue([auto1, auto2], autoplay: false);
      controller.addToQueue(manualNotDownloaded);
      controller.addToQueue(manualDownloaded);
      // manualQueue = [manual_bad, manual_good], autoQueue = [auto2]
      // (auto1 es currentTrack tras setQueue).

      await controller.playCurrent().timeout(const Duration(seconds: 5));
      await pumpEventQueue();

      expect(controller.state.currentTrack?.id, 'manual_good',
          reason: 'debe encontrar y reproducir la manual descargada antes de mirar la automática');
      expect(controller.state.manualQueue, isEmpty,
          reason: 'manual_bad (antes del índice encontrado) se descarta porque nunca sonó; '
              'manual_good se consumió al reproducirse');
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['auto2'],
          reason: 'la automática no debe tocarse en absoluto mientras la manual tenga un candidato');
    });
  });

  // Fase 7.B: radio / cola infinita (sin IA, D-10). El disparo vive al final
  // de playCurrent() (vía finally, ver _maybeFetchRadio en el controlador),
  // así que basta con avanzar la reproducción con una autoQueue corta para
  // ejercitarlo — no hace falta instrumentar cada método que toca la cola
  // por separado.
  group('SyncoraPlayerController — radio / cola infinita (Fase 7.B)', () {
    late FakeAudioEngine engine;
    late TestableExtractionService extractionService;
    late FakeRadioService radioService;

    SyncoraPlayerController buildController({bool radioEnabled = true}) {
      return SyncoraPlayerController(
        engine: engine,
        extractionService: extractionService,
        radioService: radioService,
        radioEnabledGetter: () => radioEnabled,
      );
    }

    setUp(() {
      engine = FakeAudioEngine();
      extractionService = TestableExtractionService();
      radioService = FakeRadioService();
    });

    test('se dispara cuando autoQueue queda en <=5 tras un avance y anexa el lote sin tocar manualQueue',
        () async {
      final controller = buildController();
      controller.init();
      addTearDown(controller.dispose);

      radioService.nextBatch = const [
        SyncoraTrack(id: 'radio1', title: 'Radio 1'),
        SyncoraTrack(id: 'radio2', title: 'Radio 2'),
      ];

      final tracks = [
        const SyncoraTrack(id: 'c1', title: 'C1', artistId: 1),
        const SyncoraTrack(id: 'c2', title: 'C2', artistId: 1),
      ]; // current=c1, autoQueue=[c2] (1 <= 5: dispara en el playCurrent de setQueue)

      // setQueue primero: con nada sonando, addToQueue promovería la pista a
      // currentTrack en vez de dejarla en manualQueue (P0.3, ver test de
      // arriba) — se agrega DESPUÉS para aislar el comportamiento "no toca
      // manualQueue" de la radio, no el de promoción.
      await controller.setQueue(tracks, autoplay: true);
      controller.addToQueue(const SyncoraTrack(id: 'manual1', title: 'Manual'));
      await pumpEventQueue();

      expect(radioService.callCount, 1);
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['c2', 'radio1', 'radio2'],
          reason: 'el lote se anexa AL FINAL de autoQueue');
      expect(controller.state.manualQueue.map((t) => t.id).toList(), ['manual1'],
          reason: 'la radio nunca toca la cola manual (D-1)');
    });

    test('no dispara si el toggle de Configuración está desactivado', () async {
      final controller = buildController(radioEnabled: false);
      controller.init();
      addTearDown(controller.dispose);

      radioService.nextBatch = const [SyncoraTrack(id: 'radio1', title: 'Radio 1')];
      final tracks = [
        const SyncoraTrack(id: 'c1', title: 'C1', artistId: 1),
        const SyncoraTrack(id: 'c2', title: 'C2', artistId: 1),
      ];

      await controller.setQueue(tracks, autoplay: true);
      await pumpEventQueue();

      expect(radioService.callCount, 0);
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['c2']);
    });

    test('no dispara si autoQueue todavía tiene más de 5 pistas', () async {
      final controller = buildController();
      controller.init();
      addTearDown(controller.dispose);

      radioService.nextBatch = const [SyncoraTrack(id: 'radio1', title: 'Radio 1')];
      final tracks = List.generate(
        8,
        (i) => SyncoraTrack(id: 'c$i', title: 'C$i', artistId: 1),
      ); // current=c0, autoQueue tiene 7 pistas (> 5)

      await controller.setQueue(tracks, autoplay: true);
      await pumpEventQueue();

      expect(radioService.callCount, 0);
      expect(controller.state.autoQueue.length, 7);
    });

    test('un fetch ya en curso no dispara uno segundo en paralelo (guard _isFetchingRadio)', () async {
      final controller = buildController();
      controller.init();
      addTearDown(controller.dispose);

      final hold = radioService.holdNextBatch();
      final tracks = [
        const SyncoraTrack(id: 'c1', title: 'C1', artistId: 1),
        const SyncoraTrack(id: 'c2', title: 'C2', artistId: 1),
      ];
      await controller.setQueue(tracks, autoplay: true); // dispara el primer fetch, queda retenido
      await pumpEventQueue();
      expect(radioService.callCount, 1);

      // Otra transición mientras el primer fetch sigue pendiente: no debe
      // disparar un segundo fetch en paralelo.
      await controller.skipToNext();
      await pumpEventQueue();
      expect(radioService.callCount, 1, reason: 'el guard _isFetchingRadio evita fetches concurrentes');

      hold.complete(const [SyncoraTrack(id: 'radioX', title: 'Radio X')]);
      await pumpEventQueue();
    });

    test('un lote que llega tarde tras un cambio de contexto (activeContextId) se descarta en silencio',
        () async {
      final controller = buildController();
      controller.init();
      addTearDown(controller.dispose);

      final hold = radioService.holdNextBatch();
      final tracksA = [
        const SyncoraTrack(id: 'a1', title: 'A1', artistId: 1),
        const SyncoraTrack(id: 'a2', title: 'A2', artistId: 1),
      ];
      await controller.setQueue(tracksA, autoplay: true, activeContextId: 'ctx_a');
      await pumpEventQueue();
      expect(radioService.callCount, 1, reason: 'el primer setQueue ya dispara el fetch (autoQueue=1<=5)');

      // El usuario cambia de contexto ANTES de que el fetch retenido resuelva.
      // (El guard _isFetchingRadio ya bloquearía un segundo disparo de
      // cualquier forma mientras el primero sigue pendiente; se deja
      // autoQueue > 5 aquí para que el escenario sea realista incluso si
      // ese guard cambiara de implementación.)
      final tracksB = [
        const SyncoraTrack(id: 'b1', title: 'B1', artistId: 2),
        const SyncoraTrack(id: 'b2', title: 'B2', artistId: 2),
        const SyncoraTrack(id: 'b3', title: 'B3', artistId: 2),
        const SyncoraTrack(id: 'b4', title: 'B4', artistId: 2),
        const SyncoraTrack(id: 'b5', title: 'B5', artistId: 2),
        const SyncoraTrack(id: 'b6', title: 'B6', artistId: 2),
        const SyncoraTrack(id: 'b7', title: 'B7', artistId: 2),
      ]; // autoQueue queda con 6 pistas (> 5).
      await controller.setQueue(tracksB, autoplay: true, activeContextId: 'ctx_b');
      await pumpEventQueue();

      // Ahora resuelve el fetch viejo, originado para ctx_a.
      hold.complete(const [SyncoraTrack(id: 'stale_radio', title: 'Stale')]);
      await pumpEventQueue();

      expect(
        controller.state.autoQueue.any((t) => t.id == 'stale_radio'),
        isFalse,
        reason: 'el lote se originó para ctx_a; el contexto activo ya es ctx_b, debe descartarse',
      );
      expect(controller.state.activeContextId, 'ctx_b');
    });

    // Revisión independiente de 7.B, bug #1: comparar `activeContextId` no
    // protegía nada en el caso común, porque la mayoría de los `setQueue()`
    // de la app (búsqueda, inicio, artista, track_tile) lo pasan en `null`
    // — `null != null` nunca es verdadero. El fix usa un contador
    // `_contextGeneration` que se incrementa en TODO `setQueue()`, tenga o
    // no `activeContextId`.
    test('un lote que llega tarde tras cambiar de contexto SIN activeContextId (ambos null) también se descarta',
        () async {
      final controller = buildController();
      controller.init();
      addTearDown(controller.dispose);

      final hold = radioService.holdNextBatch();
      final tracksA = [
        const SyncoraTrack(id: 'a1', title: 'A1', artistId: 1),
        const SyncoraTrack(id: 'a2', title: 'A2', artistId: 1),
      ];
      await controller.setQueue(tracksA, autoplay: true); // sin activeContextId (null)
      await pumpEventQueue();
      expect(radioService.callCount, 1);

      // El usuario reproduce otra canción desde búsqueda (también sin
      // activeContextId) ANTES de que el fetch retenido resuelva — el
      // escenario exacto reportado en la revisión.
      final tracksB = [
        const SyncoraTrack(id: 'b1', title: 'B1', artistId: 2),
        const SyncoraTrack(id: 'b2', title: 'B2', artistId: 2),
      ];
      await controller.setQueue(tracksB, autoplay: true); // también sin activeContextId (null)
      await pumpEventQueue();

      hold.complete(const [SyncoraTrack(id: 'stale_radio', title: 'Stale')]);
      await pumpEventQueue();

      expect(
        controller.state.autoQueue.any((t) => t.id == 'stale_radio'),
        isFalse,
        reason: 'con `activeContextId` nulo en ambos setQueue, "null != null" nunca detectaba el '
            'cambio de contexto — el contador de generación sí debe detectarlo',
      );
      expect(controller.state.currentTrack?.id, 'b1');
    });

    // Contraparte del test anterior: el fix no debe ser tan agresivo que
    // descarte lotes válidos al simplemente avanzar dentro del MISMO
    // contexto (_advance()/skipToNext() no incrementan _contextGeneration).
    test('un lote que resuelve mientras se avanza DENTRO del mismo contexto (misma playlist) sí se anexa',
        () async {
      final controller = buildController();
      controller.init();
      addTearDown(controller.dispose);

      final hold = radioService.holdNextBatch();
      final tracks = [
        const SyncoraTrack(id: 'p1', title: 'P1', artistId: 1),
        const SyncoraTrack(id: 'p2', title: 'P2', artistId: 1),
      ];
      await controller.setQueue(tracks, autoplay: true, activeContextId: 'ctx_p');
      await pumpEventQueue();
      expect(radioService.callCount, 1);

      // Avanza dentro de la MISMA playlist (no un setQueue nuevo) mientras
      // el fetch sigue pendiente.
      await controller.skipToNext();
      await pumpEventQueue();

      hold.complete(const [SyncoraTrack(id: 'radio_ok', title: 'Radio OK')]);
      await pumpEventQueue();

      expect(controller.state.autoQueue.any((t) => t.id == 'radio_ok'), isTrue,
          reason: 'avanzar dentro del mismo contexto no debe invalidar un lote en vuelo');
    });

    // Revisión independiente de 7.B, bug #2: faltaba incluir el historial de
    // reproducción en el set de exclusión, así que la radio podía reofrecer
    // una pista que el usuario ya escuchó y dejó atrás.
    test('el set de exclusión enviado a generateBatch incluye el historial de reproducción', () async {
      final controller = buildController();
      controller.init();
      addTearDown(controller.dispose);

      final tracks = [
        const SyncoraTrack(id: 'h1', title: 'H1', artistId: 1),
        const SyncoraTrack(id: 'h2', title: 'H2', artistId: 1),
        const SyncoraTrack(id: 'h3', title: 'H3', artistId: 1),
      ];
      await controller.setQueue(tracks, autoplay: true); // current=h1, autoQueue=[h2,h3] (2<=5: dispara ya)
      await pumpEventQueue();
      expect(radioService.callCount, 1);

      // Avanzar deja a h1 en el historial; el siguiente disparo de radio
      // debe excluirlo.
      await controller.skipToNext(); // current=h2, history=[h1]
      await pumpEventQueue();

      expect(radioService.lastExcludeIds, isNotNull);
      expect(radioService.lastExcludeIds, contains('h1'),
          reason: 'h1 ya está en el historial (fue reproducida y consumida) — no debe reofrecerse');
    });

    // Revisión independiente de 7.B, bug #3: el toggle de Configuración debe
    // apagar TODO el auto-relleno de autoQueue, no solo _maybeFetchRadio —
    // _tryAutoplay (el mecanismo de Autoplay previo a 7.B, disparado cuando
    // AMBAS colas se agotan del todo) no consultaba el toggle.
    test('el toggle de radio desactivado también apaga el Autoplay de recomendaciones (_tryAutoplay)', () async {
      final controller = SyncoraPlayerController(
        engine: engine,
        extractionService: extractionService,
        // DeezerApi real, pero el toggle debe cortar ANTES de tocar la red
        // — si esto llegara a hacer una petición real, el test sería lento/
        // flaky; el hecho de que no lo sea confirma que el guard corta a
        // tiempo.
        deezerApi: DeezerApi(),
        radioService: radioService,
        radioEnabledGetter: () => false,
      );
      controller.init();
      addTearDown(controller.dispose);

      await controller.setQueue(
        const [SyncoraTrack(id: 'only1', title: 'Only 1')],
        autoplay: true,
      ); // current=only1, ambas colas quedan vacías, sin repeat-all

      await controller.skipToNext(); // se agotan ambas colas -> intenta Autoplay -> debe abortar por el toggle
      await pumpEventQueue();

      expect(controller.state.currentTrack?.id, 'only1',
          reason: 'sin autoplay, no hay a dónde avanzar: currentTrack se queda como estaba');
      expect(controller.state.engine.playing, isFalse, reason: 'sin nada más que reproducir, el motor se pausa');
    });

    // Revisión independiente de 7.B, bug #5: sin este guard, cada cambio de
    // pista mientras el usuario está offline disparaba 5 peticiones de red
    // condenadas de antemano.
    test('no dispara ningún fetch de radio si el usuario está offline', () async {
      final controller = SyncoraPlayerController(
        engine: engine,
        extractionService: extractionService,
        radioService: radioService,
        radioEnabledGetter: () => true,
        isConnectedGetter: () => false,
      );
      controller.init();
      addTearDown(controller.dispose);

      final tracks = [
        const SyncoraTrack(id: 'o1', title: 'O1', artistId: 1),
        const SyncoraTrack(id: 'o2', title: 'O2', artistId: 1),
      ];
      await controller.setQueue(tracks, autoplay: true);
      await pumpEventQueue();

      expect(radioService.callCount, 0);
    });
  });

  // Fase 7.C: Auto-Skip inteligente completo (auto-skip lógico, ver
  // docs/plan_fase_7.md). Cubre 7.C.1 (toast), 7.C.2 (marcado gris de
  // sesión, D-21), 7.C.3 (guard de cascada) y 7.C.4 (integración con la cola
  // dual, ya construida/probada en 7.A — acá solo se confirma que un fallo
  // en la cola MANUAL no descoloca la automática). También cubre H-6 (aviso
  // de pausa por error persistente 403/red, que ya funcionaba pero nunca
  // llegaba a la UI).
  group('SyncoraPlayerController — Auto-Skip inteligente (Fase 7.C) + H-6', () {
    late FakeAudioEngine engine;
    late TestableExtractionService extractionService;
    late SyncoraPlayerController controller;

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

    test('7.C.1/7.C.2: 1 fallo lógico aislado dispara el aviso logicalSkip, marca la pista '
        'en gris y salta a la siguiente', () async {
      final tracks = [
        const SyncoraTrack(id: 'not_found_track', title: 'Rota'),
        const SyncoraTrack(id: 'track2', title: 'Track 2'),
      ];

      await controller.setQueue(tracks, autoplay: true);

      expect(controller.state.currentTrack?.id, 'track2', reason: 'debe saltar automáticamente');
      expect(controller.state.notice, isNotNull);
      expect(controller.state.notice!.kind, PlayerNoticeKind.logicalSkip);
      expect(controller.state.notice!.message, 'Rota no disponible — saltada');
      expect(controller.state.unavailableTrackIds, contains('not_found_track'),
          reason: '7.C.2/D-21: la pista rota debe quedar marcada de sesión');
      expect(controller.state.unavailableTrackIds.contains('track2'), isFalse,
          reason: 'la pista que sí resolvió no debe marcarse');
    });

    test('7.C.3: 3 fallos lógicos seguidos detienen el auto-skip, pausan el motor y disparan '
        'el aviso de guard de cascada', () async {
      final chain = [
        const SyncoraTrack(id: 'bad1', title: 'Bad 1'),
        const SyncoraTrack(id: 'bad2', title: 'Bad 2'),
        const SyncoraTrack(id: 'bad3', title: 'Bad 3'),
        const SyncoraTrack(id: 'good', title: 'Good'),
      ];
      extractionService.notFoundIds.addAll(['bad1', 'bad2', 'bad3']);

      await controller.setQueue(chain, autoplay: true);

      expect(controller.state.currentTrack?.id, 'bad3',
          reason: 'se detiene EN la 3ra pista fallida, no sigue saltando hacia "good"');
      expect(controller.state.engine.playing, isFalse, reason: 'el motor debe quedar pausado');
      // Revisión de código: `engine.playing` en `isFalse` por sí solo pasa
      // trivialmente si nunca sonó nada (estado inicial). Verificar que
      // pause() se llamó de verdad distingue "se pausó" de "nunca arrancó".
      expect(engine.pauseCallCount, 1, reason: 'el guard debe pausar el motor explícitamente');
      expect(controller.state.notice, isNotNull);
      expect(controller.state.notice!.kind, PlayerNoticeKind.cascadeGuard);
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['good'],
          reason: '"good" nunca se toca: el guard corta la cadena antes de llegar a ella');
      expect(controller.state.unavailableTrackIds, containsAll(['bad1', 'bad2', 'bad3']));
    });

    test('7.C.3: resumeAfterCascadeGuard() ("Reintentar") resetea el contador y avanza una vez más',
        () async {
      final chain = [
        const SyncoraTrack(id: 'bad1', title: 'Bad 1'),
        const SyncoraTrack(id: 'bad2', title: 'Bad 2'),
        const SyncoraTrack(id: 'bad3', title: 'Bad 3'),
        const SyncoraTrack(id: 'good', title: 'Good'),
      ];
      extractionService.notFoundIds.addAll(['bad1', 'bad2', 'bad3']);
      await controller.setQueue(chain, autoplay: true);
      expect(controller.state.currentTrack?.id, 'bad3'); // guard activo

      await controller.resumeAfterCascadeGuard();

      expect(controller.state.currentTrack?.id, 'good');
      expect(controller.state.engine.playing, isTrue);
    });

    // Revisión de código (bug real, corregido): resumeAfterCascadeGuard()
    // reseteaba el contador ANTES de pasar por el guard de reentrada de
    // skipToNext(). Un segundo tap en "Reintentar" mientras la cascada del
    // primero sigue en vuelo quedaba bloqueado por el guard de
    // _isTransitioning (correcto), PERO ya había reseteado el contador a 0
    // de todos modos — si esa cascada en vuelo ya había acumulado fallos
    // reales (no solo el bad3 original, sino nuevos fallos posteriores al
    // "Reintentar"), ese progreso real se borraba en silencio, dándole a la
    // cascada 3 fallos MÁS de margen de los que le corresponden. Un solo
    // tap (sin nada pendiente) no alcanza para exhibir el bug, porque
    // skipToNext() YA resetea el contador él mismo tras pasar su guard —
    // hace falta que el segundo tap llegue MIENTRAS el contador de la
    // cascada del primero ya es != 0, para que el reset de más sea
    // observable.
    test('7.C.3: un segundo tap en "Reintentar" mientras la cascada del primero sigue en vuelo NO '
        'debe borrar el progreso real de fallos ya acumulado', () async {
      final chain = [
        const SyncoraTrack(id: 'bad1', title: 'Bad 1'),
        const SyncoraTrack(id: 'bad2', title: 'Bad 2'),
        const SyncoraTrack(id: 'bad3', title: 'Bad 3'),
        const SyncoraTrack(id: 'badA', title: 'Bad A'),
        const SyncoraTrack(id: 'badB', title: 'Bad B'),
        const SyncoraTrack(id: 'badC', title: 'Bad C'),
        const SyncoraTrack(id: 'good', title: 'Good'),
      ];
      extractionService.notFoundIds.addAll(['bad1', 'bad2', 'bad3', 'badA', 'badB', 'badC']);
      await controller.setQueue(chain, autoplay: true);
      expect(controller.state.currentTrack?.id, 'bad3'); // guard activo tras bad1/bad2/bad3

      // Retiene la resolución de 'badB' para poder inyectar el segundo tap
      // justo en medio de la cascada nueva que dispara el primer
      // "Reintentar" — después de que badA ya falló (contador real=1) pero
      // antes de que badB resuelva.
      final heldB = extractionService.holdResolution('badB');
      final firstResume = controller.resumeAfterCascadeGuard(); // resetea a 0 -> badA falla (contador=1) -> badB pendiente
      await pumpEventQueue();

      // Segundo tap mientras badB sigue pendiente: el guard _isTransitioning
      // de skipToNext() lo descarta correctamente (no dispara una extracción
      // de más), pero el bug original reseteaba el contador ANTES de llegar
      // a ese guard, borrando el "1" real que badA ya había acumulado.
      await controller.resumeAfterCascadeGuard();

      heldB.complete(const ExtractionFailure(
        requestId: 'req_badB',
        error: ExtractionError.notFound,
        message: 'Track not found',
      ));
      await firstResume;
      await pumpEventQueue();

      // Con el fix: badA(1) + badB(2) + badC(3) alcanza el umbral EN badC ->
      // el guard se dispara de nuevo ahí, nunca llega a "good".
      // Con el bug: el reset de más del segundo tap deja badA(1) -> [borrado
      // a 0 por el segundo tap] -> badB(1) + badC(2) -> el guard NO se
      // dispara y la cadena sigue hasta "good".
      expect(controller.state.currentTrack?.id, 'badC',
          reason: 'debe detenerse en badC (3er fallo real de esta cascada nueva: badA+badB+badC), '
              'no seguir de largo hasta "good" por culpa de un reset de más');
      expect(controller.state.engine.playing, isFalse);
      expect(controller.state.notice?.kind, PlayerNoticeKind.cascadeGuard);
      expect(extractionService.extractCount, 6,
          reason: 'bad1+bad2+bad3+badA+badB+badC = 6; el segundo tap no debe haber disparado una '
              'séptima llamada a extractUrl (fue descartado por el guard)');
    });

    // Revisión de código (bug real, corregido): el test original intercalaba
    // un `skipToNext()` manual entre el éxito y los dos fallos siguientes —
    // pero `skipToNext()` YA resetea el contador por sí mismo (es un entry
    // point manual), así que ese test pasaba igual aunque el reset real (el
    // que debería dispararse por la extracción exitosa en
    // `_onPlaybackStartedSuccessfully`) no existiera — confirmado por
    // mutación quitando ese reset. Reescrito para que TODA la cadena
    // (fallo→éxito→fallo→fallo→éxito) ocurra sin pasar por NINGÚN entry
    // point público: el avance desde la pista exitosa usa
    // `engine.emitError()`, que dispara `_advanceAndPlay()` directamente
    // desde `_onEngineState` (mismo camino que el test 9 del grupo base),
    // sin tocar el contador él mismo — a diferencia de skipToNext().
    test('7.C.3: el contador se resetea al reproducir algo con éxito entre fallos, sin depender '
        'del reset de ningún entry point manual (falla, éxito, falla, falla no debe activar el '
        'guard con solo 2 fallos "reales")', () async {
      final chain = [
        const SyncoraTrack(id: 'bad1', title: 'Bad 1'),
        const SyncoraTrack(id: 'good1', title: 'Good 1'),
        const SyncoraTrack(id: 'bad2', title: 'Bad 2'),
        const SyncoraTrack(id: 'bad3', title: 'Bad 3'),
        const SyncoraTrack(id: 'good2', title: 'Good 2'),
      ];
      extractionService.notFoundIds.addAll(['bad1', 'bad2', 'bad3']);

      await controller.setQueue(chain, autoplay: true);
      // bad1 falla (cascada interna, contador=1) -> good1 resuelve y
      // reproduce con éxito: debe resetear el contador él mismo, sin ayuda
      // de ningún entry point manual.
      expect(controller.state.currentTrack?.id, 'good1');
      expect(controller.state.engine.playing, isTrue);

      // Avanza SOLO vía _onEngineState (error del motor -> _advanceAndPlay()
      // directo), nunca vía skipToNext()/playFromQueue()/setQueue() — esos
      // resetearían el contador por su cuenta y enmascararían si el reset
      // real (el que se está probando acá) funciona o no.
      engine.emitError();
      await pumpEventQueue();

      // Si el reset de good1 NO hubiera funcionado, el contador arrastrado
      // (1) + bad2(2) + bad3(3) alcanzaría el umbral EN bad3 y el guard
      // cortaría la cadena ahí, sin llegar nunca a good2.
      expect(controller.state.currentTrack?.id, 'good2',
          reason: 'solo 2 fallos "reales" tras el reset -> no debe activar el guard');
      expect(controller.state.engine.playing, isTrue);
      expect(controller.state.notice?.kind, isNot(PlayerNoticeKind.cascadeGuard),
          reason: 'el guard nunca debió dispararse en esta cadena');
    });

    // Revisión de código (bug real, corregido): _playCurrentInternal tiene
    // DOS caminos de éxito — extracción online y descarga local — y el
    // reset del contador solo vivía en el de extracción. Una descarga local
    // reproducida con éxito ENTRE dos fallos lógicos no rompía la racha.
    test('7.C.3: una descarga local reproducida con éxito entre fallos también resetea el '
        'contador (no solo la extracción online)', () async {
      final db = SyncoraDatabase(NativeDatabase.memory());
      final localEngine = FakeAudioEngine();
      final localController = SyncoraPlayerController(
        engine: localEngine,
        extractionService: extractionService,
        downloadedTrackDao: db.downloadedTrackDao,
      );
      localController.init();

      const downloadedTrack = SyncoraTrack(id: 'local_good', title: 'Local Good');
      await db.downloadedTrackDao.insertOrUpdate(DownloadedTracksCompanion.insert(
        trackId: downloadedTrack.deezerId,
        artistId: 0,
        albumId: 0,
        title: downloadedTrack.title,
        artistName: downloadedTrack.artist,
        albumName: '',
        coverUrl: '',
        localAudioPath: '/fake/${downloadedTrack.id}.mp3',
        durationMs: 1000,
        downloadState: const Value(2),
      ));

      final chain = [
        const SyncoraTrack(id: 'bad1', title: 'Bad 1'),
        const SyncoraTrack(id: 'bad2', title: 'Bad 2'),
        downloadedTrack,
        const SyncoraTrack(id: 'bad3', title: 'Bad 3'),
        const SyncoraTrack(id: 'good_final', title: 'Good Final'),
      ];
      extractionService.notFoundIds.addAll(['bad1', 'bad2', 'bad3']);

      await localController.setQueue(chain, autoplay: true).timeout(const Duration(seconds: 5));
      await pumpEventQueue();

      // Una reproducción exitosa (local o extraída) no auto-avanza por sí
      // sola — se queda sonando. Para seguir probando la cadena hacia
      // adelante (bad3, luego good_final) sin pasar por ningún entry point
      // manual (que resetearía el contador por su cuenta y volvería a
      // enmascarar el bug, igual que en el test de arriba), se usa
      // `emitError()`: dispara `_advanceAndPlay()` directo desde
      // `_onEngineState`, sin tocar el contador él mismo.
      expect(localController.state.currentTrack?.id, 'local_good');
      expect(localController.state.engine.playing, isTrue);
      localEngine.emitError();
      await pumpEventQueue();

      expect(localController.state.currentTrack?.id, 'good_final',
          reason: 'si el reset de la descarga local no funcionara, bad2(2)+bad3(3) alcanzaría el '
              'umbral en bad3 y el guard cortaría la cadena ahí, sin llegar a good_final');
      expect(localController.state.notice?.kind, isNot(PlayerNoticeKind.cascadeGuard));

      localController.dispose();
      await db.close();
    });

    // Revisión de código (bug real, corregido): skipToPrevious() era el
    // único entry point manual que no reseteaba el contador (setQueue/
    // playFromQueue/skipToNext sí lo hacían). El aviso/marcado gris debe
    // seguir aplicando igual venga de "siguiente" o "anterior" (eso no
    // cambia) — lo que se prueba acá es que el CONTADOR no arrastre una
    // cascada vieja de "siguiente" hacia una sesión de escucha iniciada
    // con "anterior".
    test('7.C.3: skipToPrevious() también resetea el contador — sin esto, retroceder desde un '
        'guard activo y volver a fallar re-dispara el guard con un conteo viejo en vez de '
        'arrancar limpio', () async {
      final chain = [
        const SyncoraTrack(id: 'bad1', title: 'Bad 1'),
        const SyncoraTrack(id: 'bad2', title: 'Bad 2'),
        const SyncoraTrack(id: 'bad3', title: 'Bad 3'),
        const SyncoraTrack(id: 'good', title: 'Good'),
      ];
      extractionService.notFoundIds.addAll(['bad1', 'bad2', 'bad3']);
      await controller.setQueue(chain, autoplay: true);
      expect(controller.state.currentTrack?.id, 'bad3'); // guard activo: contador=3, motor pausado

      // "Anterior" desde el guard: la posición nunca avanzó de 0 (bad3
      // jamás llegó a sonar), así que no es un reinicio — retrocede de
      // verdad al historial, a bad2, y lo reintenta. bad2 sigue en
      // notFoundIds: vuelve a fallar. Si skipToPrevious() NO reseteara el
      // contador, este fallo aislado (que normalmente sería el primero de
      // una cascada nueva) heredaría el 3 de antes y re-dispararía el guard
      // de inmediato, sin darle a la cadena la chance de llegar a "good".
      await controller.skipToPrevious();

      expect(controller.state.currentTrack?.id, 'good',
          reason: 'con el reset, bad2(1)+bad3(2) no alcanzan el umbral -> la cadena llega a "good"');
      expect(controller.state.engine.playing, isTrue);
    });

    test('7.C.4: un fallo lógico en la cola MANUAL no descoloca la automática (D-1 se respeta)',
        () async {
      final auto1 = const SyncoraTrack(id: 'auto1', title: 'Auto 1');
      final auto2 = const SyncoraTrack(id: 'auto2', title: 'Auto 2');
      final manualBad = const SyncoraTrack(id: 'manual_bad', title: 'Manual Rota');
      extractionService.notFoundIds.add('manual_bad');

      await controller.setQueue([auto1, auto2], autoplay: true); // current=auto1, autoQueue=[auto2]
      controller.addToQueue(manualBad); // manualQueue=[manual_bad]

      await controller.skipToNext(); // D-1: la manual precede -> intenta manual_bad, falla, cae a auto2

      expect(controller.state.currentTrack?.id, 'auto2',
          reason: 'tras el fallo de la manual, debe caer en la automática intacta');
      expect(controller.state.currentOrigin, QueueOrigin.auto);
      expect(controller.state.manualQueue, isEmpty,
          reason: 'manual_bad se consumió (se eliminó de SU cola de origen) al fallar');
      expect(controller.state.autoQueue, isEmpty,
          reason: 'auto2 pasó a currentTrack; la automática no perdió nada de más');
      expect(controller.state.unavailableTrackIds, contains('manual_bad'));
    });

    test('H-6: error rateLimited persistente dispara el aviso persistentError, NO marca la pista '
        'en gris ni dispara el toast de auto-skip lógico', () async {
      extractionService.forcedError = ExtractionError.rateLimited;

      await controller.setQueue(
        const [SyncoraTrack(id: 'track1', title: 'Track 1')],
        autoplay: true,
      );

      expect(controller.state.engine.playing, isFalse);
      // Revisión de código: distingue "se pausó de verdad" de "nunca sonó
      // nada" (ver comentario equivalente en el test del guard de cascada).
      expect(engine.pauseCallCount, 1, reason: 'el guard 403/red debe pausar el motor explícitamente');
      expect(controller.state.notice, isNotNull);
      expect(controller.state.notice!.kind, PlayerNoticeKind.persistentError);
      expect(controller.state.notice!.kind, isNot(PlayerNoticeKind.logicalSkip));
      expect(controller.state.unavailableTrackIds, isEmpty,
          reason: 'H-6 es un caso distinto de 7.C: no es un auto-skip, la pista no está rota, '
              'solo pausada');
    });

    test('el skip manual del usuario (skipToNext sin fallo) NO dispara ningún aviso', () async {
      final tracks = [
        const SyncoraTrack(id: 't1', title: 'T1'),
        const SyncoraTrack(id: 't2', title: 'T2'),
      ];
      await controller.setQueue(tracks, autoplay: true);
      await controller.skipToNext();

      expect(controller.state.currentTrack?.id, 't2');
      expect(controller.state.notice, isNull);
      expect(controller.state.unavailableTrackIds, isEmpty);
    });

    test('el salto silencioso offline (_skipSilently) NO dispara ningún aviso ni marca nada en gris',
        () async {
      final db = SyncoraDatabase(NativeDatabase.memory());
      final offlineController = SyncoraPlayerController(
        engine: FakeAudioEngine(),
        extractionService: TestableExtractionService(),
        downloadedTrackDao: db.downloadedTrackDao,
        isConnectedGetter: () => false,
      );
      offlineController.init();

      final tracks = [
        const SyncoraTrack(id: 'off1', title: 'Off 1'),
        const SyncoraTrack(id: 'off2', title: 'Off 2'),
      ];
      await offlineController.setQueue(tracks, autoplay: true).timeout(const Duration(seconds: 5));
      await pumpEventQueue();

      expect(offlineController.state.currentTrack, isNull,
          reason: 'ninguna está descargada: el salto silencioso termina en "nada sonando"');
      expect(offlineController.state.notice, isNull);
      expect(offlineController.state.unavailableTrackIds, isEmpty);

      offlineController.dispose();
      await db.close();
    });
  });

  // Fase 7.D: crossfade entre pistas descargadas/cacheadas localmente
  // (Pitfall #17 — nunca en streaming, solo local-a-local). Estas pruebas
  // verifican la DECISIÓN del controlador (¿corresponde crossfade o la
  // transición normal de siempre?), no el fade en sí — eso se prueba contra
  // `CrossfadeAudioEngine` en `test/features/player/audio_engine/
  // crossfade_audio_engine_test.dart`. Aquí `engine` es un `FakeAudioEngine`
  // plano (sin el wrapper) para aislar la lógica de las 4 condiciones del
  // controlador.
  group('SyncoraPlayerController — crossfade (Fase 7.D)', () {
    late FakeAudioEngine engine;
    late TestableExtractionService extractionService;
    late SyncoraDatabase db;

    Future<void> seedDownloaded(SyncoraTrack track) async {
      await db.downloadedTrackDao.insertOrUpdate(DownloadedTracksCompanion.insert(
        trackId: track.deezerId,
        artistId: 0,
        albumId: 0,
        title: track.title,
        artistName: track.artist,
        albumName: '',
        coverUrl: '',
        localAudioPath: '/fake/${track.id}.mp3',
        durationMs: 1000,
        downloadState: const Value(2),
      ));
    }

    setUp(() {
      engine = FakeAudioEngine();
      extractionService = TestableExtractionService();
      db = SyncoraDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    SyncoraPlayerController buildController(Duration crossfadeDuration) {
      final controller = SyncoraPlayerController(
        engine: engine,
        extractionService: extractionService,
        downloadedTrackDao: db.downloadedTrackDao,
        crossfadeDurationGetter: () => crossfadeDuration,
      );
      controller.init();
      return controller;
    }

    test('setting > 0 + pista actual y siguiente descargadas -> usa crossfadeToLocalSource, no stop+load+play',
        () async {
      final t1 = const SyncoraTrack(id: 't1', title: 'Uno');
      final t2 = const SyncoraTrack(id: 't2', title: 'Dos');
      await seedDownloaded(t1);
      await seedDownloaded(t2);

      final controller = buildController(const Duration(seconds: 4));
      addTearDown(controller.dispose);

      await controller.setQueue([t1, t2], autoplay: true);
      expect(controller.state.currentTrack?.id, 't1');
      expect(engine.crossfadeCallCount, 0);
      final stopsAfterFirstTrack = engine.stopCallCount;

      await controller.skipToNext();

      expect(controller.state.currentTrack?.id, 't2');
      expect(engine.crossfadeCallCount, 1);
      expect(engine.lastCrossfadePath, '/fake/t2.mp3');
      expect(engine.lastCrossfadeDuration, const Duration(seconds: 4));
      expect(engine.stopCallCount, stopsAfterFirstTrack,
          reason: 'el crossfade reemplaza la secuencia stop()+setLocalSource()+play(): no debe haber un stop() extra');
    });

    test('setting en "off" (Duration.zero) -> transición normal, nunca crossfade', () async {
      final t1 = const SyncoraTrack(id: 't1', title: 'Uno');
      final t2 = const SyncoraTrack(id: 't2', title: 'Dos');
      await seedDownloaded(t1);
      await seedDownloaded(t2);

      final controller = buildController(Duration.zero);
      addTearDown(controller.dispose);

      await controller.setQueue([t1, t2], autoplay: true);
      final stopsAfterFirstTrack = engine.stopCallCount;

      await controller.skipToNext();

      expect(controller.state.currentTrack?.id, 't2');
      expect(engine.crossfadeCallCount, 0);
      expect(engine.stopCallCount, greaterThan(stopsAfterFirstTrack),
          reason: 'sin crossfade, la transición normal sí pasa por stop()');
    });

    test('la pista SIGUIENTE no está descargada -> transición normal, nunca crossfade', () async {
      final t1 = const SyncoraTrack(id: 't1', title: 'Uno');
      final t2 = const SyncoraTrack(id: 't2', title: 'Dos (sin descargar)');
      await seedDownloaded(t1);
      // t2 no se descarga: se resolvería por streaming.

      final controller = buildController(const Duration(seconds: 4));
      addTearDown(controller.dispose);

      await controller.setQueue([t1, t2], autoplay: true);
      await controller.skipToNext();

      expect(controller.state.currentTrack?.id, 't2');
      expect(engine.crossfadeCallCount, 0);
    });

    test('la pista ACTUAL vino de streaming -> nunca crossfade, aunque la siguiente sí esté descargada '
        '(Pitfall #17: nunca local-a-streaming ni streaming-a-local)', () async {
      final t1 = const SyncoraTrack(id: 't1', title: 'Uno (streaming)');
      final t2 = const SyncoraTrack(id: 't2', title: 'Dos');
      // t1 no se descarga: se reproduce por streaming (TestableExtractionService
      // resuelve con éxito cualquier id no marcado como forcedError/notFound).
      await seedDownloaded(t2);

      final controller = buildController(const Duration(seconds: 4));
      addTearDown(controller.dispose);

      await controller.setQueue([t1, t2], autoplay: true);
      expect(controller.state.currentTrack?.id, 't1');
      expect(controller.state.engine.playing, isTrue,
          reason: 'condición 4 del crossfade (motor reproduciendo algo) debe cumplirse igual, '
              'para aislar que lo que bloquea acá es la condición 3 (origen local)');

      await controller.skipToNext();

      expect(controller.state.currentTrack?.id, 't2');
      expect(engine.crossfadeCallCount, 0);
    });

    // P0 (revisión de código): el diseño original solo podía crossfade-ar
    // si el usuario tocaba "siguiente" a mano mientras la pista sonaba —
    // nunca en el flujo natural de una playlist, que es el caso de uso
    // principal. Este test cubre exactamente ESO: nadie llama a
    // skipToNext/skipToPrevious/playFromQueue, solo se simulan los ticks
    // de posición que el motor emitiría solo mientras la pista suena.
    test(
        'crossfade PREVENTIVO: se dispara cuando el tiempo restante de la pista actual cae por '
        'debajo de la duración configurada, SIN que el usuario toque nada', () async {
      final t1 = const SyncoraTrack(id: 't1', title: 'Uno');
      final t2 = const SyncoraTrack(id: 't2', title: 'Dos');
      await seedDownloaded(t1);
      await seedDownloaded(t2);

      final controller = buildController(const Duration(seconds: 4));
      addTearDown(controller.dispose);

      await controller.setQueue([t1, t2], autoplay: true);
      expect(controller.state.currentTrack?.id, 't1');
      expect(controller.state.engine.playing, isTrue);
      // FakeAudioEngine.setLocalSource siempre emite duration=180s (ver su
      // definición más arriba en este archivo).
      expect(controller.state.engine.duration, const Duration(seconds: 180));
      expect(engine.crossfadeCallCount, 0);

      // Tick de posición a 176s de 180s -> quedan exactamente 4s, igual al
      // umbral configurado. Nadie llamó a ningún método de skip manual.
      engine.emitState(controller.state.engine.copyWith(position: const Duration(seconds: 176)));
      await pumpEventQueue();

      expect(controller.state.currentTrack?.id, 't2',
          reason: 'debe avanzar solo, disparado por el propio tick de posición');
      expect(engine.crossfadeCallCount, 1);
      expect(engine.lastCrossfadePath, '/fake/t2.mp3');
      expect(engine.lastCrossfadeDuration, const Duration(seconds: 4));
    });

    test(
        'crossfade PREVENTIVO: no se dispara dos veces para la misma pista (ticks repetidos dentro '
        'de la ventana no duplican el intento)', () async {
      final t1 = const SyncoraTrack(id: 't1', title: 'Uno');
      final t2 = const SyncoraTrack(id: 't2', title: 'Dos');
      await seedDownloaded(t1);
      await seedDownloaded(t2);

      final controller = buildController(const Duration(seconds: 4));
      addTearDown(controller.dispose);

      await controller.setQueue([t1, t2], autoplay: true);

      // Varios ticks seguidos, todos dentro de la ventana de crossfade.
      engine.emitState(controller.state.engine.copyWith(position: const Duration(seconds: 177)));
      await pumpEventQueue();
      engine.emitState(controller.state.engine.copyWith(position: const Duration(seconds: 178)));
      await pumpEventQueue();
      engine.emitState(controller.state.engine.copyWith(position: const Duration(seconds: 179)));
      await pumpEventQueue();

      expect(controller.state.currentTrack?.id, 't2');
      expect(engine.crossfadeCallCount, 1,
          reason: 'una vez que se avanzó a t2, los ticks siguientes ya no pertenecen a la pista '
              'que disparó el intento original');
    });

    test(
        'crossfade PREVENTIVO: usa como duración real del fade el mínimo entre la configurada y '
        'lo que en verdad queda de la pista saliente', () async {
      final t1 = const SyncoraTrack(id: 't1', title: 'Uno');
      final t2 = const SyncoraTrack(id: 't2', title: 'Dos');
      await seedDownloaded(t1);
      await seedDownloaded(t2);

      // Configurado a 6s, pero al momento del tick solo quedan 2s reales.
      final controller = buildController(const Duration(seconds: 6));
      addTearDown(controller.dispose);

      await controller.setQueue([t1, t2], autoplay: true);
      engine.emitState(controller.state.engine.copyWith(position: const Duration(seconds: 178)));
      await pumpEventQueue();

      expect(engine.crossfadeCallCount, 1);
      expect(engine.lastCrossfadeDuration, const Duration(seconds: 2),
          reason: 'el fade no debe extenderse más allá de lo que realmente queda de la pista '
              'saliente, para no llegar a su EOF natural a mitad del fade');
    });

    // Bug real de pruebas manuales (Windows, crossfade activado): "al
    // terminar una canción salta como 6 canciones". Con solo DOS pistas en la
    // cola el bug era invisible (tras avanzar a t2 no quedaba ninguna
    // siguiente que peekear), por eso ninguno de los tests de arriba lo
    // detectó. Con la cola llena, cada tick de posición que seguía llegando
    // del motor SALIENTE (con su posición ya cerca del EOF) mientras
    // `currentTrack` era la pista nueva disparaba otro crossfade preventivo,
    // encadenando un avance de cola por tick.
    test(
        'crossfade PREVENTIVO: los ticks del motor saliente que siguen llegando DESPUÉS de avanzar '
        'no encadenan más avances (no salta varias pistas de golpe)', () async {
      const tracks = [
        SyncoraTrack(id: 't1', title: 'Uno'),
        SyncoraTrack(id: 't2', title: 'Dos'),
        SyncoraTrack(id: 't3', title: 'Tres'),
        SyncoraTrack(id: 't4', title: 'Cuatro'),
        SyncoraTrack(id: 't5', title: 'Cinco'),
        SyncoraTrack(id: 't6', title: 'Seis'),
      ];
      for (final t in tracks) {
        await seedDownloaded(t);
      }

      final controller = buildController(const Duration(seconds: 4));
      addTearDown(controller.dispose);

      await controller.setQueue(tracks, autoplay: true);
      expect(controller.state.currentTrack?.id, 't1');

      // Tick que dispara el crossfade preventivo hacia t2.
      engine.emitState(controller.state.engine.copyWith(position: const Duration(seconds: 176)));
      await pumpEventQueue();
      expect(controller.state.currentTrack?.id, 't2');
      expect(engine.crossfadeCallCount, 1);

      // Ticks siguientes con la posición del motor saliente (todavía cerca de
      // su EOF): el ramp de volumen sigue corriendo y el motor no terminó de
      // entregar la pista nueva.
      for (final ms in [176500, 177000, 177500, 178000, 178500, 179000]) {
        engine.emitState(controller.state.engine.copyWith(position: Duration(milliseconds: ms)));
        await pumpEventQueue();
      }

      expect(controller.state.currentTrack?.id, 't2',
          reason: 'un solo avance por transición: los ticks del motor saliente no deben '
              'encadenar más crossfades');
      expect(engine.crossfadeCallCount, 1);
      expect(controller.state.autoQueue.map((t) => t.id).toList(), ['t3', 't4', 't5', 't6'],
          reason: 'la cola solo debe haber perdido la pista a la que se avanzó');
    });

    // Segunda mitad de la cascada: el fin natural de la pista SALIENTE puede
    // llegar mientras el crossfade ya avanzó la cola por su cuenta. Atenderlo
    // sería un segundo avance para la misma transición.
    test(
        'crossfade PREVENTIVO: el fin de pista del motor saliente durante el fade no dispara un '
        'segundo avance', () async {
      const tracks = [
        SyncoraTrack(id: 't1', title: 'Uno'),
        SyncoraTrack(id: 't2', title: 'Dos'),
        SyncoraTrack(id: 't3', title: 'Tres'),
      ];
      for (final t in tracks) {
        await seedDownloaded(t);
      }

      final controller = buildController(const Duration(seconds: 4));
      addTearDown(controller.dispose);

      await controller.setQueue(tracks, autoplay: true);
      engine.emitState(controller.state.engine.copyWith(position: const Duration(seconds: 176)));
      await pumpEventQueue();
      expect(controller.state.currentTrack?.id, 't2');

      engine.triggerCompletion();
      await pumpEventQueue();

      expect(controller.state.currentTrack?.id, 't2',
          reason: 'el avance de esta transición ya lo hizo el crossfade al arrancar el fade');
      expect(engine.crossfadeCallCount, 1);
    });

    // El guard de la cascada no puede ser permanente: si quedara pegado, el
    // crossfade preventivo dejaría de funcionar para el resto de la sesión
    // (y `_onComplete` dejaría de avanzar la cola, trabando el reproductor).
    test('crossfade PREVENTIVO: el guard se libera al terminar el fade y la pista siguiente '
        'también puede crossfade-ar', () async {
      const tracks = [
        SyncoraTrack(id: 't1', title: 'Uno'),
        SyncoraTrack(id: 't2', title: 'Dos'),
        SyncoraTrack(id: 't3', title: 'Tres'),
      ];
      for (final t in tracks) {
        await seedDownloaded(t);
      }

      final controller = buildController(const Duration(milliseconds: 200));
      addTearDown(controller.dispose);

      await controller.setQueue(tracks, autoplay: true);
      engine.emitState(
          controller.state.engine.copyWith(position: const Duration(milliseconds: 179850)));
      await pumpEventQueue();
      expect(controller.state.currentTrack?.id, 't2');
      expect(engine.crossfadeCallCount, 1);

      // Más allá de la duración del fade + el margen de asentamiento.
      await Future<void>.delayed(const Duration(milliseconds: 800));

      engine.emitState(
          controller.state.engine.copyWith(position: const Duration(milliseconds: 179850)));
      await pumpEventQueue();

      expect(controller.state.currentTrack?.id, 't3');
      expect(engine.crossfadeCallCount, 2);
    });

    test('crossfade PREVENTIVO: con repeat-one no avanza de cola (la pista se repite entera)',
        () async {
      const t1 = SyncoraTrack(id: 't1', title: 'Uno');
      const t2 = SyncoraTrack(id: 't2', title: 'Dos');
      await seedDownloaded(t1);
      await seedDownloaded(t2);

      final controller = buildController(const Duration(seconds: 4));
      addTearDown(controller.dispose);

      await controller.setQueue([t1, t2], autoplay: true);
      controller.setRepeatMode(SyncoraRepeatMode.one);

      engine.emitState(controller.state.engine.copyWith(position: const Duration(seconds: 176)));
      await pumpEventQueue();

      expect(controller.state.currentTrack?.id, 't1');
      expect(engine.crossfadeCallCount, 0);
    });
  });

  // Fase 7.A.6: esquema nuevo de sesión persistida (currentTrack/currentOrigin
  // + ambas colas + historial). Una sesión en el formato viejo (queue plana +
  // currentIndex) o que no matchee el esquema se descarta por completo.
  group('PlayerSessionData — persistencia de sesión (Fase 7.A)', () {
    test('toJson/fromJson reconstruye currentTrack, currentOrigin, ambas colas e historial', () {
      const t1 = SyncoraTrack(id: 't1', title: 'T1');
      const t2 = SyncoraTrack(id: 't2', title: 'T2');
      const t3 = SyncoraTrack(id: 't3', title: 'T3');
      const session = PlayerSessionData(
        currentTrack: t1,
        currentOrigin: QueueOrigin.manual,
        manualQueue: [t2],
        autoQueue: [t3],
        originalContextTracks: [t1, t2, t3],
        history: [HistoryEntry(t2, QueueOrigin.auto)],
        positionSeconds: 42,
        repeatMode: SyncoraRepeatMode.all,
        shuffle: true,
        activeContextId: 'playlist_1',
      );

      final json = session.toJson();
      final restored = PlayerSessionData.fromJson(json);

      expect(restored, isNotNull);
      expect(restored!.currentTrack?.id, 't1');
      expect(restored.currentOrigin, QueueOrigin.manual);
      expect(restored.manualQueue.map((t) => t.id).toList(), ['t2']);
      expect(restored.autoQueue.map((t) => t.id).toList(), ['t3']);
      expect(restored.originalContextTracks.map((t) => t.id).toList(), ['t1', 't2', 't3']);
      expect(restored.history.length, 1);
      expect(restored.history.first.track.id, 't2');
      expect(restored.history.first.origin, QueueOrigin.auto);
      expect(restored.positionSeconds, 42);
      expect(restored.repeatMode, SyncoraRepeatMode.all);
      expect(restored.shuffle, isTrue);
      expect(restored.activeContextId, 'playlist_1');
    });

    test('una sesión con el formato viejo (queue/currentIndex planos) se descarta sin crashear', () {
      final oldFormatJson = {
        'queue': [
          {'id': 't1', 'title': 'T1'},
        ],
        'currentIndex': 0,
        'positionSeconds': 10,
        'repeatMode': 'off',
        'shuffle': false,
      };

      expect(() => PlayerSessionData.fromJson(oldFormatJson), returnsNormally);
      expect(PlayerSessionData.fromJson(oldFormatJson), isNull);
    });

    test('JSON sin schemaVersion reconocible también se descarta', () {
      expect(PlayerSessionData.fromJson({'schemaVersion': 1, 'manualQueue': [], 'autoQueue': []}), isNull);
      expect(PlayerSessionData.fromJson(<String, dynamic>{}), isNull);
    });

    // P0.5: una entrada de `history` corrupta NO debe tirar la sesión
    // completa — currentTrack, ambas colas y la posición deben sobrevivir,
    // degradando solo el historial a vacío.
    test('una entrada de history corrupta se aísla: currentTrack/colas/posición sobreviven (P0.5)', () {
      final json = {
        'schemaVersion': 2,
        'currentTrack': const SyncoraTrack(id: 't1', title: 'T1').toJson(),
        'currentOrigin': 'auto',
        'manualQueue': [const SyncoraTrack(id: 'm1', title: 'M1').toJson()],
        'autoQueue': [const SyncoraTrack(id: 'a1', title: 'A1').toJson()],
        'originalContextTracks': [const SyncoraTrack(id: 't1', title: 'T1').toJson()],
        // Entrada de historial deliberadamente corrupta (falta 'track', que
        // HistoryEntry.fromJson espera como Map).
        'history': [
          {'origin': 'auto'},
        ],
        'positionSeconds': 77,
        'repeatMode': 'off',
        'shuffle': false,
        'activeContextId': 'playlist_1',
      };

      final restored = PlayerSessionData.fromJson(json);

      expect(restored, isNotNull, reason: 'la sesión completa no debe descartarse por un historial corrupto');
      expect(restored!.currentTrack?.id, 't1');
      expect(restored.manualQueue.map((t) => t.id).toList(), ['m1']);
      expect(restored.autoQueue.map((t) => t.id).toList(), ['a1']);
      expect(restored.positionSeconds, 77);
      expect(restored.history, isEmpty, reason: 'el historial se degrada a vacío, no crashea el resto');
    });
  });
}
