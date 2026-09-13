import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/extraction/extraction_service.dart';
import 'package:syncora_player/core/extraction/models/extraction_request.dart';
import 'package:syncora_player/core/extraction/models/extraction_result.dart';
import 'package:syncora_player/features/player/audio_engine/audio_engine_state.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/session/player_session_storage.dart';
import 'package:syncora_player/features/player/syncora_player_controller.dart';

/// Ronda 3, Bundle B (cola, aleatorio y sesion).
///
/// H-R3-3 es la causa raiz de tres sintomas que el reporte listaba por
/// separado: "solo se reproducen ciertas canciones", "no suena el resto de la
/// playlist" y "la cola de radio infinita empieza antes de tiempo".

class _SilentEngine implements AudioEngine {
  final _stateController = StreamController<AudioEngineState>.broadcast();
  final _completionController = StreamController<void>.broadcast();
  final _logController = StreamController<String>.broadcast();
  AudioEngineState _state = AudioEngineState.initial;

  @override
  Stream<AudioEngineState> get stateStream => _stateController.stream;
  @override
  Stream<void> get completionStream => _completionController.stream;
  @override
  Stream<String> get logStream => _logController.stream;
  @override
  Duration get position => _state.position;
  @override
  Duration get duration => _state.duration;

  @override
  Future<void> setUrl(String url, {Map<String, String>? headers, Duration? initialPosition}) async {
    _state = _state.copyWith(processingState: AudioProcessingState.ready);
    _stateController.add(_state);
  }

  @override
  Future<void> setLocalSource(String path, {Duration? initialPosition}) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> microFadeOut() async {}
  @override
  Future<void> setSkipSilenceEnabled(bool enabled) async {}
  @override
  Future<void> crossfadeToLocalSource(String path, Duration duration) async {}
  @override
  Future<void> dispose() async {
    await _stateController.close();
    await _completionController.close();
    await _logController.close();
  }
}

class _OkExtraction implements ExtractionService {
  @override
  Stream<String> get onLogMessage => const Stream.empty();

  @override
  Future<ExtractionResult> extractUrl(
    String videoId, {
    String? trackTitle,
    String? trackArtist,
    int? durationSeconds,
    ExtractionPriority priority = ExtractionPriority.streaming,
    String? quality,
  }) async =>
      const ExtractionSuccess(requestId: 't', streamUrl: 'https://x.test/a', headers: {});

  @override
  void resetEngine() {}
  @override
  void dispose() {}
}

/// Almacen de sesion en memoria, para probar el viaje de ida y vuelta sin
/// tocar disco.
class _MemorySessionStorage extends PlayerSessionStorage {
  PlayerSessionData? data;

  @override
  Future<PlayerSessionData?> loadSession() async => data;

  @override
  Future<void> saveSession({
    SyncoraTrack? currentTrack,
    QueueOrigin? currentOrigin,
    required List<SyncoraTrack> manualQueue,
    required List<SyncoraTrack> autoQueue,
    required List<SyncoraTrack> originalContextTracks,
    required List<HistoryEntry> history,
    required int positionSeconds,
    double volume = 1.0,
    required SyncoraRepeatMode repeatMode,
    required bool shuffle,
    String? activeContextId,
  }) async {
    data = PlayerSessionData(
      currentTrack: currentTrack,
      currentOrigin: currentOrigin,
      manualQueue: manualQueue,
      autoQueue: autoQueue,
      originalContextTracks: originalContextTracks,
      history: history,
      positionSeconds: positionSeconds,
      volume: volume,
      repeatMode: repeatMode,
      shuffle: shuffle,
      activeContextId: activeContextId,
    );
  }
}

List<SyncoraTrack> _playlist(int n) =>
    List.generate(n, (i) => SyncoraTrack(id: '${i + 1}', title: 'Pista ${i + 1}'));

SyncoraPlayerController _controller({PlayerSessionStorage? storage}) {
  final c = SyncoraPlayerController(
    engine: _SilentEngine(),
    extractionService: _OkExtraction(),
    sessionStorage: storage,
  );
  c.init();
  return c;
}

void main() {
  group('B1 - aleatorio desde un indice conserva la playlist entera', () {
    test('empezar por la pista 50 de 60 deja 59 en cola, no 9', () async {
      // H-R3-3 exacto. Antes: `tracks.sublist(startIndex + 1)` y LUEGO
      // mezclar, asi que las 49 anteriores se descartaban para siempre.
      final c = _controller();
      c.setShuffle(true);

      await c.setQueue(_playlist(60), startIndex: 49, autoplay: false);

      expect(c.state.autoQueue.length, 59);
      expect(c.state.currentTrack?.id, '50');
      final idsEnCola = c.state.autoQueue.map((t) => t.id).toSet();
      expect(idsEnCola.contains('1'), isTrue, reason: 'las anteriores tambien deben sonar');
      expect(idsEnCola.contains('50'), isFalse, reason: 'la que suena no se repite en la cola');
      c.dispose();
    });

    test('en modo normal se sigue descartando lo anterior al indice', () async {
      // Comportamiento diseñado que NO cambia: sin aleatorio el orden es el de
      // la lista y el usuario pidio empezar por ahi.
      final c = _controller();

      await c.setQueue(_playlist(60), startIndex: 49, autoplay: false);

      expect(c.state.autoQueue.length, 10);
      expect(c.state.autoQueue.first.id, '51');
      c.dispose();
    });

    test('la cola aleatoria sale realmente mezclada', () async {
      final c = _controller();
      c.setShuffle(true);

      await c.setQueue(_playlist(60), startIndex: 0, autoplay: false);
      final orden = c.state.autoQueue.map((t) => t.id).toList();
      final ordenado = _playlist(60).sublist(1).map((t) => t.id).toList();

      expect(orden.length, 59);
      expect(orden.toSet(), ordenado.toSet());
      expect(orden, isNot(equals(ordenado)));
      c.dispose();
    });
  });

  group('B4 - regenerar cola', () {
    test('rehace la cola y descarta el bloque de radio', () async {
      final c = _controller();
      await c.setQueue(_playlist(10), startIndex: 0, autoplay: false);
      // Mete pistas ajenas al contexto en la cola automatica, que es
      // exactamente la forma que tiene un lote de radio ya anexado.
      c.interleaveIntoAutoQueue(const [
        SyncoraTrack(id: 'radio-1', title: 'Radio 1'),
        SyncoraTrack(id: 'radio-2', title: 'Radio 2'),
      ]);
      expect(c.state.autoQueue.any((t) => t.id.startsWith('radio-')), isTrue,
          reason: 'precondicion: la cola tiene radio antes de regenerar');

      final ok = c.regenerateAutoQueue();

      expect(ok, isTrue);
      expect(
        c.state.autoQueue.any((t) => t.id.startsWith('radio-')),
        isFalse,
        reason: 'si conservara la radio, el usuario veria las mismas sugerencias',
      );
      expect(c.state.autoQueue.length, 9, reason: '10 del contexto menos la que suena');
      c.dispose();
    });

    test('NUNCA toca la cola manual (D-2) ni la pista que suena', () async {
      final c = _controller();
      await c.setQueue(_playlist(10), startIndex: 0, autoplay: false);
      c.addToQueue(const SyncoraTrack(id: 'manual-1', title: 'Manual'));

      final sonando = c.state.currentTrack?.id;
      c.regenerateAutoQueue();

      expect(c.state.manualQueue.map((t) => t.id).toList(), ['manual-1']);
      expect(c.state.currentTrack?.id, sonando);
      c.dispose();
    });

    test('no ofrece nada si no hay contexto del que regenerar', () async {
      final c = _controller();
      expect(c.regenerateAutoQueue(), isFalse);
      c.dispose();
    });

    test('con el contexto agotado NO repone la playlist: refresca la radio', () async {
      // Ronda 3 bis. Estando en la ultima cancion, "regenerar cola" devolvia
      // media playlist ya escuchada. A esa altura lo que se quiere son otras
      // recomendaciones, no repetir lo de antes.
      final c = _controller();
      await c.setQueue(_playlist(3), startIndex: 0, autoplay: false);
      await c.skipToNext();
      await c.skipToNext();
      c.interleaveIntoAutoQueue(const [SyncoraTrack(id: 'radio-1', title: 'Radio 1')]);

      final ok = c.regenerateAutoQueue();

      expect(ok, isTrue);
      expect(c.state.autoQueue, isEmpty,
          reason: 'se descarta la radio vieja; el lote nuevo lo trae _maybeFetchRadio');
      c.dispose();
    });

    test('sin radio, el contexto agotado si se repone (el boton debe hacer algo)', () async {
      final c = SyncoraPlayerController(
        engine: _SilentEngine(),
        extractionService: _OkExtraction(),
        radioEnabledGetter: () => false,
      );
      c.init();
      await c.setQueue(_playlist(3), startIndex: 0, autoplay: false);
      await c.skipToNext();
      await c.skipToNext();

      final ok = c.regenerateAutoQueue();

      expect(ok, isTrue);
      expect(c.state.autoQueue.length, 2, reason: '3 del contexto menos la que suena');
      expect(c.state.autoQueue.any((t) => t.id == c.state.currentTrack!.id), isFalse);
      c.dispose();
    });

    test('en aleatorio, regenerar da otra mezcla', () async {
      final c = _controller();
      c.setShuffle(true);
      await c.setQueue(_playlist(40), startIndex: 0, autoplay: false);
      final antes = c.state.autoQueue.map((t) => t.id).toList();

      c.regenerateAutoQueue();
      final despues = c.state.autoQueue.map((t) => t.id).toList();

      expect(despues.toSet(), antes.toSet());
      expect(despues, isNot(equals(antes)));
      c.dispose();
    });
  });

  group('B2 - restauracion de sesion', () {
    test('continuidad exacta: la cola se restaura tal cual quedo', () async {
      // Decision de producto de esta ronda: reanudar es continuar, no barajar
      // de nuevo. Quien quiera otra mezcla tiene "Regenerar cola".
      final storage = _MemorySessionStorage();
      final primera = _controller(storage: storage);
      primera.setShuffle(true);
      await primera.setQueue(_playlist(20), startIndex: 0, autoplay: false);
      final ordenGuardado = primera.state.autoQueue.map((t) => t.id).toList();
      primera.dispose();

      final segunda = _controller(storage: storage);
      await pumpEventQueue();

      expect(segunda.state.autoQueue.map((t) => t.id).toList(), ordenGuardado);
      segunda.dispose();
    });

    test('lo que el usuario quito a mano NO vuelve al reabrir la app', () async {
      // Revision de la ronda 3 (P1). La primera version de B2 repoblaba la
      // cola desde el contexto cuando no quedaba nada de el, para reparar
      // sesiones afectadas por H-R3-3. Pero esa misma condicion la cumple el
      // usuario que vacia la cola a proposito: al siguiente arranque se le
      // devolvian todas las pistas que habia quitado, en silencio y en cada
      // reinicio. Se retiro la red de seguridad; este test fija que no vuelva.
      final storage = _MemorySessionStorage();
      final primera = _controller(storage: storage);
      await primera.setQueue(_playlist(3), startIndex: 0, autoplay: false);
      // Desliza para eliminar las dos que quedaban en cola.
      primera.removeFromQueue(QueueOrigin.auto, 1);
      primera.removeFromQueue(QueueOrigin.auto, 0);
      expect(primera.state.autoQueue, isEmpty);
      primera.dispose();

      final segunda = _controller(storage: storage);
      await pumpEventQueue();

      expect(segunda.state.autoQueue, isEmpty,
          reason: 'vaciar la cola a mano es una decision del usuario, no un estado a reparar');
      expect(segunda.state.currentTrack?.id, '1');
      segunda.dispose();
    });

    test('la cola con radio anexada se restaura tal cual', () async {
      final storage = _MemorySessionStorage();
      await storage.saveSession(
        currentTrack: const SyncoraTrack(id: '1', title: 'Pista 1'),
        currentOrigin: QueueOrigin.auto,
        manualQueue: const [],
        autoQueue: const [
          SyncoraTrack(id: '5', title: 'Pista 5'),
          SyncoraTrack(id: 'radio-1', title: 'Radio 1'),
        ],
        originalContextTracks: _playlist(20),
        history: const [],
        positionSeconds: 0,
        repeatMode: SyncoraRepeatMode.off,
        shuffle: false,
      );

      final c = _controller(storage: storage);
      await pumpEventQueue();

      expect(c.state.autoQueue.map((t) => t.id).toList(), ['5', 'radio-1']);
      c.dispose();
    });
  });
}
