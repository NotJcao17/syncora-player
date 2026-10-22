import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:syncora_player/features/player/audio_engine/audio_engine_state.dart';
import 'package:syncora_player/features/player/audio_engine/just_audio_engine.dart';

/// Plataforma nativa falsa de just_audio: publica los eventos como lo hace el
/// `AudioPlayer.java` de la 0.10.
class _FakePlatform extends JustAudioPlatform {
  _FakePlayer? player;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async => player = _FakePlayer(request.id);

  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async => DisposePlayerResponse();

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(DisposeAllPlayersRequest request) async =>
      DisposeAllPlayersResponse();
}

class _FakePlayer extends AudioPlayerPlatform {
  _FakePlayer(super.id);

  final _events = StreamController<PlaybackEventMessage>.broadcast();
  ProcessingStateMessage _state = ProcessingStateMessage.idle;
  Duration _position = Duration.zero;
  int? _errorCode;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => const Stream.empty();

  void _broadcast() => _events.add(PlaybackEventMessage(
        processingState: _state,
        updateTime: DateTime.now(),
        updatePosition: _position,
        bufferedPosition: _position,
        duration: const Duration(minutes: 3),
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
        errorCode: _errorCode,
        errorMessage: _errorCode == null ? null : 'Source error',
      ));

  /// `onPlayerError` de ExoPlayer: `sendError(..., switchToIdle: true)`.
  void failWithSourceError() {
    _errorCode = 0; // ExoPlaybackException.TYPE_SOURCE
    _state = ProcessingStateMessage.idle;
    _broadcast();
  }

  void reportPosition(Duration p) {
    _position = p;
    _broadcast();
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _errorCode = null;
    _position = request.initialPosition ?? Duration.zero;
    _state = ProcessingStateMessage.ready;
    _broadcast();
    return LoadResponse(duration: const Duration(minutes: 3));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _broadcast();
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _position = request.position ?? Duration.zero;
    _broadcast();
    return SeekResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async => SetVolumeResponse();

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async => SetSpeedResponse();

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async => SetPitchResponse();

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(SetSkipSilenceRequest request) async => SetSkipSilenceResponse();

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async => SetLoopModeResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(SetShuffleModeRequest request) async => SetShuffleModeResponse();

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(SetShuffleOrderRequest request) async => SetShuffleOrderResponse();

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(SetAndroidAudioAttributesRequest request) async =>
      SetAndroidAudioAttributesResponse();

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse> setAutomaticallyWaitsToMinimizeStalling(
          SetAutomaticallyWaitsToMinimizeStallingRequest request) async =>
      SetAutomaticallyWaitsToMinimizeStallingResponse();

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      setCanUseNetworkResourcesForLiveStreamingWhilePaused(
              SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest request) async =>
          SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(SetPreferredPeakBitRateRequest request) async =>
      SetPreferredPeakBitRateResponse();

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    await _events.close();
    return DisposeResponse();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const audioSession = MethodChannel('com.ryanheise.audio_session');
  late _FakePlatform platform;

  setUp(() {
    platform = _FakePlatform();
    JustAudioPlatform.instance = platform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(audioSession, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(audioSession, null);
  });

  // Ronda 10: pausar unos minutos y darle play empezaba desde 0. En pausa
  // YouTube corta la conexión, ExoPlayer da error y just_audio 0.10 lo
  // publica como `idle` + `errorCode` (ya no como error del stream). El motor
  // lo tomaba por un `idle` cualquiera.
  test('un error de ExoPlayer (idle con errorCode) se publica como error y conserva la posición', () async {
    final engine = JustAudioEngine();
    final states = <AudioEngineState>[];
    final sub = engine.stateStream.listen(states.add);

    await engine.setLocalSource('/musica/cancion.m4a');
    await engine.play();
    platform.player!.reportPosition(const Duration(seconds: 26));
    await engine.pause();
    await pumpEventQueue();
    states.clear();

    platform.player!.failWithSourceError();
    await pumpEventQueue();

    expect(states.last.processingState, AudioProcessingState.error);
    expect(states.last.playing, isFalse);
    expect(states.last.position, const Duration(seconds: 26));
    expect(states.any((s) => s.processingState == AudioProcessingState.idle), isFalse,
        reason: 'el controlador recargaría la pista desde 0 al pulsar play');

    await sub.cancel();
    engine.dispose();
  });

  test('un stop normal sigue siendo idle, no error', () async {
    final engine = JustAudioEngine();
    final states = <AudioEngineState>[];
    final sub = engine.stateStream.listen(states.add);

    await engine.setLocalSource('/musica/cancion.m4a');
    await engine.stop();
    await pumpEventQueue();

    expect(states.last.processingState, AudioProcessingState.idle);
    await sub.cancel();
    engine.dispose();
  });
}
