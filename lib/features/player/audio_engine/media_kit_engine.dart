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

  AudioEngineState _state = AudioEngineState.initial;
  bool _skipSilence = false;

  // --- Estado interno para Skip Silence -------------------------------
  // El primer `silence_end` (fin del silencio inicial) se captura una sola vez
  // por pista; al detectarlo, se hace seek a ese instante.
  bool _seekedThisTrack = false;
  static final RegExp _silenceEndRe =
      RegExp(r'silence_end:\s*([\d.]+)');

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
      _emit(_state.copyWith(position: p));
    });
    _player.stream.duration.listen((d) {
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
      if (completed) {
        _completionController.add(null);
        _emit(_state.copyWith(
          playing: false,
          processingState: AudioProcessingState.completed,
        ));
      }
    });
    // Log de mpv → detección de bordes de silencio (Pitfall #7).
    _player.stream.log.listen(_onLog);
  }

  @override
  Stream<AudioEngineState> get stateStream => _stateController.stream;

  @override
  Stream<void> get completionStream => _completionController.stream;

  @override
  Duration get position => _player.state.position;

  @override
  Duration get duration => _player.state.duration;

  @override
  Future<void> setUrl(String url, {Map<String, String>? headers}) async {
    _seekedThisTrack = false;
    _emit(_state.copyWith(processingState: AudioProcessingState.loading));
    await _player.open(Media(url, httpHeaders: headers));
    // Si el Skip Silence ya estaba activado, re-aplicar el filtro para esta
    // nueva pista (cada open podría resetear la cadena de filtros).
    if (_skipSilence) {
      await _applySilenceFilter();
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setRate(speed);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> setSkipSilenceEnabled(bool enabled) async {
    _skipSilence = enabled;
    if (enabled) {
      await _applySilenceFilter();
    } else {
      await _removeSilenceFilter();
    }
  }

  // --- Skip Silence interno -------------------------------------------

  Future<void> _applySilenceFilter() async {
    final native = _player.platform;
    if (native is NativePlayer) {
      // Filtro de ffmpeg para detectar silencios (Pitfall #7). NO usar
      // scaletempo (es de velocidad, no de detección de silencio).
      await native.setProperty(
        'af',
        'lavfi=[silencedetect=noise=-50dB:duration=0.3]',
      );
    }
  }

  Future<void> _removeSilenceFilter() async {
    final native = _player.platform;
    if (native is NativePlayer) {
      await native.setProperty('af', '');
    }
  }

  void _onLog(PlayerLog log) {
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
    _player.dispose();
  }
}
