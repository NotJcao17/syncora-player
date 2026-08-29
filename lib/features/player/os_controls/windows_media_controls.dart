import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:smtc_windows/smtc_windows.dart';

import '../../../data/local_db/daos/playlist_dao.dart';
import '../syncora_player_controller.dart';
import '../audio_engine/audio_engine_state.dart' as engine_state;

/// Adaptador para conectar [SyncoraPlayerController] con los controles multimedia
/// nativos de Windows (SMTC — System Media Transport Controls).
///
/// Muestra título, artista, álbum y portada en la barra de tareas / panel de volumen
/// de Windows, y retransmite pulsaciones de teclas multimedia al controlador.
class WindowsMediaControls {
  final SyncoraPlayerController _controller;
  final PlaylistDao? _playlistDao;
  late final SMTCWindows _smtc;
  StreamSubscription<PressedButton>? _buttonSub;
  DateTime _lastTimelineUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposed = false;

  /// Botones que Windows dibuja al pasar el mouse por el icono de la barra de
  /// tareas. Es una API distinta de SMTC (`ITaskbarList3::ThumbBarAddButtons`,
  /// ver `windows/runner/thumbnail_toolbar.cpp`): `smtc_windows` no la expone,
  /// por eso vive en el runner nativo detrás de este canal.
  static const _thumbBar = MethodChannel('syncora/thumbbar');
  bool _isCurrentTrackLiked = false;
  String? _likedStateTrackId;
  bool? _lastPushedPlaying;
  bool? _lastPushedLiked;

bool get _isTestEnv {
  try {
    final name = WidgetsBinding.instance.runtimeType.toString();
    return name.contains('Test') || name.contains('Automated');
  } catch (_) {
    return true;
  }
}

  WindowsMediaControls(this._controller, [this._playlistDao]) {
    if (kIsWeb || !Platform.isWindows || _isTestEnv) return;

    _thumbBar.setMethodCallHandler(_onThumbBarCall);

    try {
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
    } catch (e) {
      debugPrint('[SMTCWindows] Error instantiating SMTC controls: $e');
    }
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

  Future<void> _onThumbBarCall(MethodCall call) async {
    if (_disposed || call.method != 'action') return;
    switch (call.arguments as String) {
      case 'previous':
        await _controller.skipToPrevious();
        break;
      case 'playPause':
        if (_controller.state.engine.playing) {
          await _controller.pause();
        } else {
          await _controller.play();
        }
        break;
      case 'next':
        await _controller.skipToNext();
        break;
      case 'like':
        await _toggleLike();
        break;
    }
  }

  Future<void> _toggleLike() async {
    final track = _controller.state.currentTrack;
    final dao = _playlistDao;
    if (track == null || dao == null) return;
    final trackIdInt = int.tryParse(track.id) ?? track.id.hashCode.abs();
    final nowLiked = await dao.toggleLikeTrack(
      trackId: trackIdInt,
      artistId: track.artistId ?? 0,
      albumId: track.albumId ?? 0,
      genre: track.genre ?? '',
      title: track.title,
      artistName: track.artist,
      albumName: track.album ?? '',
      coverUrl: track.coverUrl,
      durationMs: (track.duration ?? Duration.zero).inMilliseconds,
    );
    if (_controller.state.currentTrack?.id != track.id) return;
    _isCurrentTrackLiked = nowLiked;
    _likedStateTrackId = track.id;
    _pushThumbBarState();
  }

  Future<void> _refreshLikedState(String? trackId) async {
    _likedStateTrackId = trackId;
    final dao = _playlistDao;
    if (trackId == null || dao == null) {
      _isCurrentTrackLiked = false;
      _pushThumbBarState();
      return;
    }
    final trackIdInt = int.tryParse(trackId) ?? trackId.hashCode.abs();
    bool liked;
    try {
      liked = await dao.isTrackLiked(trackIdInt);
    } catch (_) {
      liked = false;
    }
    // La pista pudo cambiar mientras la consulta estaba en vuelo.
    if (_likedStateTrackId != trackId) return;
    _isCurrentTrackLiked = liked;
    _pushThumbBarState();
  }

  /// Solo cruza el canal cuando algo que los botones muestran cambió de verdad:
  /// `_onControllerChanged` corre en cada tick de posición.
  void _pushThumbBarState() {
    if (_disposed) return;
    final playing = _controller.state.engine.playing;
    if (playing == _lastPushedPlaying && _isCurrentTrackLiked == _lastPushedLiked) {
      return;
    }
    _lastPushedPlaying = playing;
    _lastPushedLiked = _isCurrentTrackLiked;
    _thumbBar.invokeMethod('update', {
      'isPlaying': playing,
      'isLiked': _isCurrentTrackLiked,
    }).catchError((_) {});
  }

  void _onControllerChanged() {
    if (_disposed) return;
    final state = _controller.state;
    final engineState = state.engine;
    final track = state.currentTrack;

    if (track?.id != _likedStateTrackId) {
      _refreshLikedState(track?.id);
    } else {
      _pushThumbBarState();
    }

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
      final thumb = track.coverUrl.isNotEmpty ? track.coverUrl : track.artUri?.toString();
      _smtc.updateMetadata(
        MusicMetadata(
          title: track.title,
          artist: track.artist,
          album: track.album ?? '',
          thumbnail: thumb != null && thumb.isNotEmpty ? thumb : null,
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
    if (_disposed || kIsWeb || !Platform.isWindows || _isTestEnv) return;
    _disposed = true;
    _buttonSub?.cancel();
    _controller.removeListener(_onControllerChanged);
    try {
      _smtc.disableSmtc();
    } catch (_) {}
  }
}
