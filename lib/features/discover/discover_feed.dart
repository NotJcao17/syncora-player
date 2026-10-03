import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/apis/deezer_provider.dart';
import '../../data/local_db/database_provider.dart';
import '../../data/models/deezer/deezer_track.dart';
import '../home/mixes/mix_engine.dart';
import '../player/audio_engine/audio_engine_factory.dart';
import '../player/audio_engine/audio_engine_state.dart';
import '../player/player_providers.dart';
import 'discover_engine.dart';
import 'preview_file_cache.dart';
import 'preview_player.dart';

@immutable
class DiscoverState {
  final List<DeezerTrack> tracks;
  final int index;
  final bool loading;
  final bool loadingMore;
  final bool exhausted;
  final String? error;
  final bool playing;
  final Duration position;
  final Duration duration;

  const DiscoverState({
    this.tracks = const [],
    this.index = 0,
    this.loading = true,
    this.loadingMore = false,
    this.exhausted = false,
    this.error,
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });

  DeezerTrack? get current => index < tracks.length ? tracks[index] : null;

  DiscoverState copyWith({
    List<DeezerTrack>? tracks,
    int? index,
    bool? loading,
    bool? loadingMore,
    bool? exhausted,
    Object? error = _keep,
    bool? playing,
    Duration? position,
    Duration? duration,
  }) =>
      DiscoverState(
        tracks: tracks ?? this.tracks,
        index: index ?? this.index,
        loading: loading ?? this.loading,
        loadingMore: loadingMore ?? this.loadingMore,
        exhausted: exhausted ?? this.exhausted,
        error: identical(error, _keep) ? this.error : error as String?,
        playing: playing ?? this.playing,
        position: position ?? this.position,
        duration: duration ?? this.duration,
      );

  static const _keep = Object();
}

/// Feed de Descubrir (Fase 8.F). Vive solo mientras la pantalla está abierta
/// (`autoDispose`): al salir se detiene la preview y se suelta el motor.
class DiscoverFeed extends Notifier<DiscoverState> {
  late PreviewPlayer _player;
  PreviewFileCache? _files;
  DiscoverSource? _source;
  final Set<int> _shown = {};
  StreamSubscription<AudioEngineState>? _stateSub;
  StreamSubscription<void>? _completionSub;
  bool _active = true;

  /// Cuántas canciones antes del final se pide el siguiente lote.
  static const int _prefetchThreshold = 4;

  @override
  DiscoverState build() {
    final api = ref.read(deezerApiProvider);
    final files = ref.read(previewFileCacheFactoryProvider)?.call();
    _files = files;
    _player = PreviewPlayer(
      engineFactory: ref.read(previewEngineFactoryProvider),
      refreshUrl: (id) async => (await api.getTrack(id)).previewUrl,
      fetchLocal: files?.fetch,
    );
    _stateSub = _player.stateStream.listen((s) {
      if (!_active) return;
      state = state.copyWith(playing: s.playing, position: s.position, duration: s.duration);
    });
    _completionSub = _player.completionStream.listen((_) => next());

    // Si el usuario reanuda el reproductor principal (mini reproductor,
    // auriculares, pantalla de bloqueo), la preview se calla: nunca dos audios
    // a la vez.
    ref.listen<bool>(playerStateProvider.select((s) => s.engine.playing), (prev, playing) {
      if (playing && state.playing) _player.pause();
    });

    ref.onDispose(() {
      _active = false;
      _stateSub?.cancel();
      _completionSub?.cancel();
      _player.dispose();
      _files?.clear();
    });

    Future.microtask(_init);
    return const DiscoverState();
  }

  Future<void> _init() async {
    try {
      final entries = await ref.read(listeningHistoryDaoProvider).getRecentHistory(limit: 500);
      final now = DateTime.now();
      _source = DiscoverSource(
        api: ref.read(deezerApiProvider),
        seedArtistIds: MixEngine.rankArtistIds(entries, now: now, limit: 6),
        listenedTrackIds: MixEngine.listenedTrackIds(entries),
      );
      await _loadMore(initial: true);
    } catch (e) {
      if (_active) state = state.copyWith(loading: false, error: 'No se pudo cargar Descubrir. Revisa tu conexión.');
    }
  }

  Future<void> retry() async {
    state = const DiscoverState();
    _shown.clear();
    await _init();
  }

  Future<void> _loadMore({bool initial = false}) async {
    final source = _source;
    if (source == null || state.loadingMore || state.exhausted) return;
    state = state.copyWith(loadingMore: true);
    try {
      // Consulta directa y no `ref.read(likedTrackIdsProvider.future)`: con
      // Riverpod 3 un provider que nadie escucha queda en pausa y ese future no
      // completa nunca. En PC pasaba (nadie más lo escuchaba en ese momento) y
      // Descubrir se quedaba cargando para siempre.
      final liked = await ref.read(playlistDaoProvider).watchLikedTrackIds().first;
      // El primer lote es más chico para que empiece a sonar antes (suele
      // bastar una sola radio); los siguientes se piden por delante.
      final batch = await source.nextBatch(exclude: {..._shown, ...liked}, minSize: initial ? 4 : 8);
      if (!_active) return;
      _shown.addAll(batch.map((t) => t.id));
      state = state.copyWith(
        tracks: [...state.tracks, ...batch],
        loading: false,
        loadingMore: false,
        exhausted: batch.isEmpty,
        error: null,
      );
      if (initial && batch.isNotEmpty) await playCurrent();
    } catch (_) {
      if (!_active) return;
      state = state.copyWith(
        loading: false,
        loadingMore: false,
        error: state.tracks.isEmpty ? 'No se pudo cargar Descubrir. Revisa tu conexión.' : null,
      );
    }
  }

  Future<void> playCurrent() async {
    final track = state.current;
    final preview = track?.previewUrl;
    if (track == null || preview == null) return;
    // Pausa el reproductor principal: la preview es un vistazo, no se mezcla.
    final controller = ref.read(syncoraPlayerControllerProvider);
    if (controller.state.engine.playing) await controller.pause();
    state = state.copyWith(position: Duration.zero, duration: const Duration(seconds: 30));
    _prefetchAround();
    await _player.play(track.id, preview);
  }

  /// Con previews en archivo (Windows): deja listas las 2 siguientes para que
  /// pasar de tarjeta sea instantáneo, y borra las que ya quedaron lejos.
  void _prefetchAround() {
    final files = _files;
    if (files == null) return;
    final i = state.index;
    final tracks = state.tracks;
    final keep = <int>{};
    for (var k = i - 1; k <= i + 2; k++) {
      if (k < 0 || k >= tracks.length) continue;
      keep.add(tracks[k].id);
      final url = tracks[k].previewUrl;
      if (k > i && url != null) unawaited(files.fetch(tracks[k].id, url));
    }
    unawaited(files.prune(keep));
  }

  /// Llamado al cambiar de tarjeta (deslizando o con los botones).
  Future<void> setIndex(int index) async {
    if (index < 0 || index >= state.tracks.length || index == state.index) return;
    state = state.copyWith(index: index);
    if (state.tracks.length - index <= _prefetchThreshold) unawaited(_loadMore());
    await playCurrent();
  }

  Future<void> next() => setIndex(state.index + 1);

  Future<void> previous() => setIndex(state.index - 1);

  Future<void> togglePlay() async {
    if (_player.currentTrackId != state.current?.id) return playCurrent();
    if (state.playing) {
      await _player.pause();
    } else {
      final controller = ref.read(syncoraPlayerControllerProvider);
      if (controller.state.engine.playing) await controller.pause();
      await _player.resume();
    }
  }

  /// Para "Escuchar completa": la preview se calla antes de que suene la
  /// canción entera en el reproductor principal.
  Future<void> stopPreview() => _player.stop();
}

final discoverFeedProvider = NotifierProvider.autoDispose<DiscoverFeed, DiscoverState>(DiscoverFeed.new);

/// Cómo se crea el motor de las previews. Sobreescribible en tests.
final previewEngineFactoryProvider = Provider<AudioEngine Function()>((ref) => createPreviewAudioEngine);

/// Previews descargadas a archivo: solo en Windows, donde abrirlas en
/// streaming con libmpv tardaba de 3 a 10+ s (ver `PreviewFileCache`). En
/// Android `null`: ExoPlayer ya hace streaming rápido.
final previewFileCacheFactoryProvider = Provider<PreviewFileCache Function()?>((ref) {
  if (kIsWeb || !Platform.isWindows) return null;
  return PreviewFileCache.new;
});
