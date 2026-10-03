// ignore_for_file: prefer_initializing_formals

import 'dart:math';

import '../../data/apis/deezer_api.dart';
import '../../data/models/deezer/deezer_track.dart';

/// Descubrir (Fase 8.F): de dónde salen las canciones del feed.
///
/// Mismo principio que el "Descubrimiento" de los mixes de Inicio: artistas
/// parecidos a los que el usuario escucha, quitando lo que ya conoce. Sin IA y
/// sin servidor: todo sale de la API pública de Deezer y del historial local.
class DiscoverEngine {
  /// Elige, de [candidates], las canciones que valen para el feed:
  /// con preview, que no estén en [exclude] (ya escuchadas, ya en "Me gusta"
  /// o ya mostradas), de artistas que no estén en [excludeArtists] (los que el
  /// usuario ya escucha: la idea es descubrir), y como mucho [maxPerArtist]
  /// por artista para que el feed no se vuelva monotemático. El orden se
  /// baraja con [random].
  static List<DeezerTrack> pickFresh(
    List<DeezerTrack> candidates, {
    required Set<int> exclude,
    Set<int> excludeArtists = const {},
    int maxPerArtist = 2,
    Random? random,
  }) {
    final perArtist = <int, int>{};
    final seen = <int>{};
    final out = <DeezerTrack>[];
    for (final t in candidates) {
      final preview = t.previewUrl;
      if (preview == null || preview.isEmpty) continue;
      if (exclude.contains(t.id) || !seen.add(t.id)) continue;
      if (excludeArtists.contains(t.artistId)) continue;
      final count = perArtist[t.artistId] ?? 0;
      if (count >= maxPerArtist) continue;
      perArtist[t.artistId] = count + 1;
      out.add(t);
    }
    out.shuffle(random ?? Random());
    return out;
  }
}

/// Va entregando lotes de canciones para el feed, una semilla a la vez.
///
/// Con historial: por cada artista que el usuario más escucha, toma uno de
/// sus relacionados que aún no se haya usado y pide su radio (una petición =
/// ~25 canciones de artistas parecidos). Sin historial, cae al top global.
class DiscoverSource {
  DiscoverSource({
    required DeezerApi api,
    required List<int> seedArtistIds,
    required Set<int> listenedTrackIds,
    Random? random,
  })  : _api = api,
        _seeds = List.of(seedArtistIds),
        _listened = listenedTrackIds,
        _random = random ?? Random();

  final DeezerApi _api;
  final List<int> _seeds;
  final Set<int> _listened;
  final Random _random;

  final Set<int> _usedRelated = {};
  int _seedCursor = 0;
  bool _chartUsed = false;

  /// Cuántas semillas probar como mucho por lote antes de rendirse.
  static const int _maxAttemptsPerBatch = 4;

  bool get hasHistory => _seeds.isNotEmpty;

  /// Siguiente lote, excluyendo [exclude] (ya mostradas o ya en "Me gusta").
  /// Lista vacía = no queda nada nuevo que ofrecer.
  Future<List<DeezerTrack>> nextBatch({required Set<int> exclude, int minSize = 8}) async {
    final all = {...exclude, ..._listened};
    if (_seeds.isEmpty) return _chartBatch(all);

    final out = <DeezerTrack>[];
    for (var attempt = 0; attempt < _maxAttemptsPerBatch && out.length < minSize; attempt++) {
      final seed = _seeds[_seedCursor % _seeds.length];
      _seedCursor++;
      final related = await _api.getArtistRelated(seed);
      final fresh = related.where((a) => !_usedRelated.contains(a.id) && !_seeds.contains(a.id)).toList();
      if (fresh.isEmpty) continue;
      final target = fresh[_random.nextInt(min(fresh.length, 6))];
      _usedRelated.add(target.id);
      final radio = await _api.getArtistRadio(target.id);
      out.addAll(DiscoverEngine.pickFresh(
        radio,
        exclude: {...all, ...out.map((t) => t.id)},
        excludeArtists: _seeds.toSet(),
        random: _random,
      ));
    }
    if (out.isEmpty) return _chartBatch(all);
    return out;
  }

  Future<List<DeezerTrack>> _chartBatch(Set<int> exclude) async {
    if (_chartUsed) return const [];
    _chartUsed = true;
    final chart = await _api.getTopCharts();
    return DiscoverEngine.pickFresh(chart, exclude: exclude, random: _random);
  }
}
