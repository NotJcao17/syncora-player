import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'audio_engine_state.dart';

/// Implementación de [AudioEngine] para **Windows** basada en `media_kit`
/// (libmpv internamente).
///
/// Maneja los headers HTTP requeridos por YouTube (Pitfall #13) vía
/// `Media(httpHeaders:)` y expone un único [stateStream] unificado.
///
/// ## Skip Silence (Pitfall #7)
///
/// Se implementa con el filtro de ffmpeg `silencedetect` (NO `scaletempo`,
/// que es un filtro de cambio de velocidad). El filtro emite eventos por el
/// log de mpv (`player.stream.log`, prefix `silencedetect`) que este motor
/// parsea para detectar el **primer sample de audio real** de la pista y hacer
/// un `seek` manual, recortando silencios al inicio/final.
///
/// El filtro se aplica/remueve dinámicamente con `NativePlayer.setProperty`
/// (`af`). El `Player` se construye con `logLevel: MPVLogLevel.info` (requisito
/// para recibir los eventos de silencedetect) y `pitch: false` (default) para
/// que `setRate` no sobrescriba la propiedad `af`.
class MediaKitEngine implements AudioEngine {
  final Player _player;

  final StreamController<AudioEngineState> _stateController =
      StreamController<AudioEngineState>.broadcast();
  final StreamController<void> _completionController =
      StreamController<void>.broadcast();
  final StreamController<String> _logStreamController =
      StreamController<String>.broadcast();

  AudioEngineState _state = AudioEngineState.initial;
  bool _skipSilence = false;

  // --- Estado interno para Skip Silence -------------------------------
  // El primer `silence_end` (fin del silencio inicial) se captura una sola vez
  // por pista; al detectarlo, se hace seek a ese instante.
  bool _seekedThisTrack = false;
  static final RegExp _silenceEndRe =
      RegExp(r'silence_end:\s*([\d.]+)');

  // --- Distinguir fin de pista real de un fallo de carga ---------------
  // libmpv emite `completed = true` tanto al llegar al final genuino de una
  // pista como cuando el stream nunca llegó a reproducir nada (URL firmada
  // vencida/con 403, respuesta vacía, formato roto) — en ambos casos es un
  // EOF desde su punto de vista. Sin esta distinción, un fallo de carga se
  // trataba exactamente igual que una canción terminada normalmente: sin
  // error visible, saltando en silencio a la siguiente pista de la cola.
  bool _hadMeaningfulPlayback = false;

  /// Construye el motor. Usa `logLevel: info` para poder capturar los eventos
  /// de `silencedetect` (Pitfall #7).
  MediaKitEngine()
      : _player = Player(
          configuration: const PlayerConfiguration(
            logLevel: MPVLogLevel.info,
            // pitch: false (default) — crítico: si fuese true, setRate
            // sobrescribiría la propiedad `af` con scaletempo.
          ),
        ) {
    _player.stream.playing.listen((playing) {
      _emit(_state.copyWith(playing: playing));
    });
    _player.stream.position.listen((p) {
      if (!_hadMeaningfulPlayback && p > const Duration(milliseconds: 500)) {
        _hadMeaningfulPlayback = true;
      }
      _emit(_state.copyWith(position: p));
    });
    _player.stream.duration.listen((d) {
      if (!_hadMeaningfulPlayback && d > Duration.zero) {
        _hadMeaningfulPlayback = true;
      }
      _emit(_state.copyWith(duration: d));
    });
    _player.stream.buffer.listen((b) {
      _emit(_state.copyWith(bufferedPosition: b));
    });
    _player.stream.buffering.listen((buf) {
      _emit(_state.copyWith(
        processingState:
            buf ? AudioProcessingState.buffering : AudioProcessingState.ready,
      ));
    });
    _player.stream.completed.listen((completed) {
      if (!completed) return;
      if (!_hadMeaningfulPlayback) {
        // EOF sin haber reproducido nada real: fallo de carga (URL/stream
        // roto), no el fin genuino de la pista. No se emite
        // `completionStream` — eso dispararía el mismo avance de cola que
        // una canción terminada normalmente, indistinguible para el usuario.
        _logStreamController.add(
          '[MediaKit] EOF sin reproducción real — tratado como fallo de carga, no como fin de pista.',
        );
        _emit(_state.copyWith(playing: false, processingState: AudioProcessingState.error));
        return;
      }
      _completionController.add(null);
      _emit(_state.copyWith(
        playing: false,
        processingState: AudioProcessingState.completed,
      ));
    });
    // Log de mpv → detección de bordes de silencio (Pitfall #7) y reenvío de
    // líneas de error/advertencia al panel de logs de la app.
    _player.stream.log.listen(_onLog);
    _configureAudioQuality();
  }

  Future<void> _configureAudioQuality() async {
    final native = _player.platform;
    if (native is NativePlayer) {
      try {
        await native.setProperty('demuxer-max-bytes', '33554432');
        await native.setProperty('demuxer-readahead-secs', '20');
        await native.setProperty('audio-buffer', '0.2');
        await native.setProperty('audio-pitch-correction', 'yes');
      } catch (_) {}
    }
  }

  @override
  Stream<AudioEngineState> get stateStream => _stateController.stream;

  @override
  Stream<void> get completionStream => _completionController.stream;

  @override
  Stream<String> get logStream => _logStreamController.stream;

  @override
  Duration get position => _player.state.position;

  @override
  Duration get duration => _player.state.duration;

  @override
  Future<void> setUrl(String url, {Map<String, String>? headers, Duration? initialPosition}) async {
    _seekedThisTrack = false;
    _hadMeaningfulPlayback = false;
    _emit(_state.copyWith(processingState: AudioProcessingState.loading));
    await _player.setVolume(_state.volume * 100.0);
    await _player.open(Media(url, httpHeaders: headers, start: initialPosition));
    // Si el Skip Silence ya estaba activado, re-aplicar el filtro para esta
    // nueva pista (cada open podría resetear la cadena de filtros).
    if (_skipSilence) {
      await _applySilenceFilter();
    }
  }

  @override
  Future<void> setLocalSource(String path, {Duration? initialPosition}) async {
    _seekedThisTrack = false;
    _hadMeaningfulPlayback = false;
    _emit(_state.copyWith(processingState: AudioProcessingState.loading));
    await _player.setVolume(_state.volume * 100.0);
    await _player.open(Media(path, start: initialPosition));
    if (_skipSilence) {
      await _applySilenceFilter();
    }
  }


  @override
  Future<void> play() async {
    await _player.setVolume(_state.volume * 100.0);
    return _player.play();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await _player.setVolume(_state.volume * 100.0);
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setRate(speed);

  @override
  Future<void> setVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    _state = _state.copyWith(volume: clamped);
    await _player.setVolume(clamped * 100.0);
    _stateController.add(_state);
  }

  @override
  Future<void> microFadeOut() async {
    final curVol = _state.volume;
    if (curVol <= 0.0) return;
    try {
      final step = curVol / 3.0;
      await _player.setVolume(((curVol - step).clamp(0.0, 1.0)) * 100.0);
      await Future.delayed(const Duration(milliseconds: 30));
      await _player.setVolume(((curVol - 2 * step).clamp(0.0, 1.0)) * 100.0);
      await Future.delayed(const Duration(milliseconds: 30));
      await _player.setVolume(0.0);
      await Future.delayed(const Duration(milliseconds: 20));
      await _player.stop();
      // Restaura inmediatamente el volumen del motor nativo a nivel canónico
      // mientras está detenido, asegurando que la siguiente pista no arranque en silencio.
      await _player.setVolume(curVol * 100.0);
    } catch (_) {}
  }

  @override
  Future<void> setSkipSilenceEnabled(bool enabled) async {
    _skipSilence = enabled;
    if (enabled) {
      await _applySilenceFilter();
    } else {
      await _removeSilenceFilter();
    }
  }

  /// Fallback SIN fade real (Fase 7.D): esta implementación cruda nunca se
  /// usa directamente para crossfade en producción — [CrossfadeAudioEngine]
  /// envuelve dos instancias de [AudioEngine] (sean cuales sean) y es donde
  /// vive el fade paralelo de verdad. Este método solo existe para que
  /// [MediaKitEngine] siga cumpliendo el contrato [AudioEngine] si algo lo
  /// invoca directo (ej. en tests); equivale a una transición normal.
  @override
  Future<void> crossfadeToLocalSource(String path, Duration duration) async {
    await stop();
    await setLocalSource(path);
    await play();
  }

  // --- Skip Silence interno -------------------------------------------

  // Deshabilitado por completo (pruebas manuales, post-Fase 7): el guard de
  // detección de fallo de abajo no alcanzó -- libmpv "acepta" la propiedad
  // `af` al asignarla (pasa la verificación de `getProperty`), pero rompe la
  // reproducción igual al terminar la pista (posible fallo en tiempo real
  // del puente lavfi que la verificación síncrona no puede ver). Hasta poder
  // depurarlo con acceso real a un dispositivo Windows, esta función es un
  // no-op a propósito -- nunca toca la propiedad `af` del motor real, así
  // que no hay filtro que romper nada, sin importar qué llame a
  // `setSkipSilenceEnabled`. El switch de Configuración también está oculto
  // en Windows (`settings_screen.dart`); esto es la segunda capa de defensa
  // por si algún estado de sesión restaurado quedó con `skipSilence: true`
  // de antes de este cambio.
  Future<void> _applySilenceFilter() async {}

  Future<void> _removeSilenceFilter() async {}

  static const Set<String> _loggableLevels = {'fatal', 'error', 'warn'};

  void _onLog(PlayerLog log) {
    // Reenviar errores/advertencias reales de mpv (HTTP, demuxer, códec) al
    // panel de logs de la app — antes se descartaban por completo salvo que
    // Skip Silence estuviera activo, así que un fallo de carga (403, stream
    // vacío/roto) no dejaba ningún rastro diagnosticable.
    if (_loggableLevels.contains(log.level)) {
      _logStreamController.add('[MediaKit:${log.level}] [${log.prefix}] ${log.text}');
    }

    if (!_skipSilence) return;
    if (log.prefix != 'silencedetect') return;
    if (_seekedThisTrack) return; // ya recortamos el intro de esta pista

    final match = _silenceEndRe.firstMatch(log.text);
    if (match != null) {
      final seconds = double.tryParse(match.group(1) ?? '');
      if (seconds != null && seconds > 0.1) {
        // `silence_end` marca el instante en el que termina el silencio
        // inicial; ese es exactamente el primer sample de audio real.
        _seekedThisTrack = true;
        _player.seek(Duration(milliseconds: (seconds * 1000).round()));
      }
    }
  }

  void _emit(AudioEngineState next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  @override
  void dispose() {
    _stateController.close();
    _completionController.close();
    _logStreamController.close();
    _player.dispose();
  }
}
