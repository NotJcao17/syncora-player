import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:smtc_windows/smtc_windows.dart';

import '../syncora_player_controller.dart';
import '../audio_engine/audio_engine_state.dart' as engine_state;

/// Adaptador para conectar [SyncoraPlayerController] con los controles multimedia
/// nativos de Windows (SMTC — System Media Transport Controls).
///
/// Muestra título, artista, álbum y portada en la barra de tareas / panel de volumen
/// de Windows, y retransmite pulsaciones de teclas multimedia al controlador.
class WindowsMediaControls {
  final SyncoraPlayerController _controller;
  late final SMTCWindows _smtc;
  StreamSubscription<PressedButton>? _buttonSub;
  DateTime _lastTimelineUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposed = false;

  WindowsMediaControls(this._controller) {
    if (kIsWeb || !Platform.isWindows) return;

    _smtc = SMTCWindows(
      config: const SMTCConfig(
        playEnabled: true,
        pauseEnabled: true,
        nextEnabled: true,
        prevEnabled: true,
        stopEnabled: true,
        fastForwardEnabled: false,
        rewindEnabled: false,
      ),
    );
    _smtc.enableSmtc();

    _buttonSub = _smtc.buttonPressStream.listen(_onButtonPressed);
    _controller.addListener(_onControllerChanged);
    _onControllerChanged();
  }

  void _onButtonPressed(PressedButton button) {
    if (_disposed) return;
    switch (button) {
      case PressedButton.play:
        _controller.play();
        break;
      case PressedButton.pause:
        _controller.pause();
        break;
      case PressedButton.next:
        _controller.skipToNext();
        break;
      case PressedButton.previous:
        _controller.skipToPrevious();
        break;
      case PressedButton.stop:
        _controller.stop();
        break;
      case PressedButton.record:
      case PressedButton.fastForward:
      case PressedButton.rewind:
      case PressedButton.channelUp:
      case PressedButton.channelDown:
        break;
    }
  }

  void _onControllerChanged() {
    if (_disposed) return;
    final state = _controller.state;
    final engineState = state.engine;
    final track = state.currentTrack;

    // 1. Playback status
    if (engineState.playing) {
      _smtc.setPlaybackStatus(PlaybackStatus.playing);
    } else if (engineState.processingState == engine_state.AudioProcessingState.idle ||
        engineState.processingState == engine_state.AudioProcessingState.completed) {
      _smtc.setPlaybackStatus(PlaybackStatus.stopped);
    } else {
      _smtc.setPlaybackStatus(PlaybackStatus.paused);
    }

    // 2. Metadata
    if (track != null) {
      _smtc.updateMetadata(
        MusicMetadata(
          title: track.title,
          artist: track.artist,
          album: track.album,
          // SMTC exige URL de red para la imagen (o null).
          thumbnail: track.artUri?.toString(),
        ),
      );
    } else {
      _smtc.clearMetadata();
    }

    // 3. Timeline (throttle: máximo 1 update por segundo para no saturar FFI)
    final now = DateTime.now();
    if (now.difference(_lastTimelineUpdate) >= const Duration(seconds: 1)) {
      _lastTimelineUpdate = now;
      final posMs = engineState.position.inMilliseconds;
      final durMs = engineState.duration.inMilliseconds;

      _smtc.updateTimeline(
        PlaybackTimeline(
          startTimeMs: 0,
          positionMs: posMs,
          endTimeMs: durMs > 0 ? durMs : posMs,
        ),
      );
    }
  }

  /// Limpia suscripciones locales. No se llama a `_smtc.dispose()` prematuramente
  /// porque destruye el runtime global de Rust de smtc_windows.
  void dispose() {
    if (_disposed || kIsWeb || !Platform.isWindows || Platform.environment.containsKey('FLUTTER_TEST')) return;
    _disposed = true;
    _buttonSub?.cancel();
    _controller.removeListener(_onControllerChanged);
    _smtc.disableSmtc();
  }
}
