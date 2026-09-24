import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'player_providers.dart';
import 'syncora_player_controller.dart';

enum SleepTimerMode { off, timed, endOfTrack }

class SleepTimerState {
  const SleepTimerState._(this.mode, this.endsAt);

  const SleepTimerState.off() : this._(SleepTimerMode.off, null);
  const SleepTimerState.timed(DateTime endsAt) : this._(SleepTimerMode.timed, endsAt);
  const SleepTimerState.endOfTrack() : this._(SleepTimerMode.endOfTrack, null);

  final SleepTimerMode mode;

  /// Solo en [SleepTimerMode.timed].
  final DateTime? endsAt;

  bool get isActive => mode != SleepTimerMode.off;
}

/// Lo único que el temporizador necesita del reproductor. Interfaz propia
/// para poder probarlo sin levantar el controlador real.
abstract class SleepTimerTarget {
  bool get isPlaying;
  double get volume;
  Future<void> setVolume(double volume);
  Future<void> pause();
}

class _ControllerSleepTimerTarget implements SleepTimerTarget {
  _ControllerSleepTimerTarget(this._controller);

  final SyncoraPlayerController _controller;

  @override
  bool get isPlaying => _controller.state.engine.playing;

  @override
  double get volume => _controller.state.engine.volume;

  @override
  Future<void> setVolume(double volume) => _controller.setVolume(volume);

  // `userInitiated: true`: para el controlador es una pausa pedida por el
  // usuario, así que ignora una completion espuria posterior (ver
  // `_onComplete`) y no reanuda sola al recuperar el foco de audio.
  @override
  Future<void> pause() => _controller.pause(userInitiated: true);
}

final sleepTimerTargetProvider = Provider<SleepTimerTarget>(
  (ref) => _ControllerSleepTimerTarget(ref.read(syncoraPlayerControllerProvider)),
);

/// Temporizador de apagado. Vive fuera del controlador a propósito: no toca
/// cola ni avance de pista, solo observa el estado y pausa.
///
/// - **Por tiempo:** al vencer baja el volumen gradualmente durante
///   [fadeDuration], pausa y deja el volumen como estaba.
/// - **Al terminar la canción:** pausa a [endOfTrackMargin] del final (los
///   ticks de posición no llegan con precisión de milisegundos y pasarse
///   dejaría sonar el arranque de la siguiente). Si la pista cambia antes
///   (salto manual, o un crossfade que arranca antes del final), pausa en
///   cuanto la nueva empieza a sonar: pausar mientras todavía carga no sirve,
///   porque el `play()` pendiente del controlador la reanudaría.
class SleepTimerNotifier extends Notifier<SleepTimerState> {
  static const fadeDuration = Duration(seconds: 8);
  static const endOfTrackMargin = Duration(milliseconds: 1200);
  static const _fadeSteps = 16;

  Timer? _timer;
  ProviderSubscription<SyncoraPlayerState>? _playerSub;
  String? _armedTrackId;
  bool _firing = false;

  /// Cambia cada vez que el temporizador se reprograma o se cancela: un
  /// fade en curso que ve otra generación se detiene sin pausar.
  int _generation = 0;

  @override
  SleepTimerState build() {
    ref.onDispose(_disposeWatchers);
    return const SleepTimerState.off();
  }

  void startTimed(Duration duration) {
    _disposeWatchers();
    state = SleepTimerState.timed(DateTime.now().add(duration));
    _timer = Timer(duration, () => _fire(fade: true));
  }

  void startEndOfTrack() {
    _disposeWatchers();
    _armedTrackId = ref.read(playerStateProvider).currentTrack?.id;
    state = const SleepTimerState.endOfTrack();
    _playerSub = ref.listen<SyncoraPlayerState>(playerStateProvider, (_, next) => _onPlayerState(next));
  }

  void cancel() {
    _disposeWatchers();
    state = const SleepTimerState.off();
  }

  void _onPlayerState(SyncoraPlayerState next) {
    if (state.mode != SleepTimerMode.endOfTrack || _firing) return;
    final engine = next.engine;
    final trackId = next.currentTrack?.id;

    if (trackId != _armedTrackId) {
      if (engine.playing) _fire(fade: false);
      return;
    }
    if (engine.playing &&
        engine.duration > endOfTrackMargin &&
        engine.position >= engine.duration - endOfTrackMargin) {
      _fire(fade: false);
    }
  }

  Future<void> _fire({required bool fade}) async {
    if (_firing) return;
    _firing = true;
    _disposeWatchers();
    final generation = _generation;
    state = const SleepTimerState.off();
    final target = ref.read(sleepTimerTargetProvider);
    try {
      if (!target.isPlaying) return;
      if (!fade) {
        await target.pause();
        return;
      }
      final original = target.volume;
      final stepDelay = fadeDuration ~/ _fadeSteps;
      for (var i = 1; i <= _fadeSteps; i++) {
        await Future<void>.delayed(stepDelay);
        // Pausó a mano, o canceló/reprogramó el temporizador: no insistir.
        if (!target.isPlaying || generation != _generation) break;
        await target.setVolume(original * (1 - i / _fadeSteps));
      }
      if (target.isPlaying && generation == _generation) await target.pause();
      await target.setVolume(original);
    } catch (_) {
    } finally {
      _firing = false;
    }
  }

  void _disposeWatchers() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _playerSub?.close();
    _playerSub = null;
    _armedTrackId = null;
  }
}

final sleepTimerProvider = NotifierProvider<SleepTimerNotifier, SleepTimerState>(SleepTimerNotifier.new);
