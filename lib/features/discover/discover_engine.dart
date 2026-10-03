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
  /// baraja con [random], salvo con [shuffle] en `false` (conserva el orden de
  /// entrada, p. ej. por popularidad).
  static List<DeezerTrack> pickFresh(
    List<DeezerTrack> candidates, {
    required Set<int> exclude,
    Set<int> excludeArtists = const {},
    int maxPerArtist = 2,
    Random? random,
    bool shuffle = true,
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
    if (shuffle) out.shuffle(random ?? Random());
    return out;
  }

  /// Intercala una canción "reconocible" y una de descubrimiento, mitad y
  /// mitad. Si una de las dos listas se acaba, lo que sobra de la otra no se
  /// usa (salvo que la reconocible esté vacía: entonces va solo
  /// descubrimiento, para no dejar el feed vacío).
  static List<DeezerTrack> interleaveHalfAndHalf(List<DeezerTrack> familiar, List<DeezerTrack> discovery) {
    if (familiar.isEmpty) return discovery;
    final n = min(familiar.length, discovery.length);
    if (n == 0) return familiar;
    return [
      for (var i = 0; i < n; i++) ...[familiar[i], discovery[i]],
    ];
  }
}

/// Va entregando lotes de canciones para el feed, una semilla a la vez.
///
/// Con historial, cada intento mezcla mitad y mitad (decisión del usuario tras
/// las pruebas: solo radio daba casi todo desconocido):
/// - **Reconocible** (un salto): las 2 canciones más populares de hasta 3
///   artistas parecidos a uno de los que más escucha.
/// - **Descubrimiento** (dos saltos): la radio de uno de esos parecidos, que
///   son canciones de artistas parecidos *a él*.
///
/// Sin historial, cae al top global.
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

  /// Artistas parecidos de los que se toman canciones populares por intento.
  static const int _familiarArtistsPerAttempt = 3;

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
      // Los más parecidos van primero en la respuesta de Deezer: se elige
      // entre los primeros, en orden aleatorio.
      final pool = fresh.take(8).toList()..shuffle(_random);
      final targets = pool.take(_familiarArtistsPerAttempt).toList();
      _usedRelated.addAll(targets.map((a) => a.id));

      // Todo en paralelo (el RateLimiter de DeezerApi se encarga del ritmo).
      final results = await Future.wait([
        _api.getArtistRadio(targets.first.id),
        for (final a in targets) _api.getArtistTopTracks(a.id, limit: 10),
      ]);

      final excluded = {...all, ...out.map((t) => t.id)};
      final familiar = <DeezerTrack>[];
      for (final top in results.skip(1)) {
        familiar.addAll(DiscoverEngine.pickFresh(
          top,
          exclude: {...excluded, ...familiar.map((t) => t.id)},
          excludeArtists: _seeds.toSet(),
          shuffle: false,
        ));
      }
      familiar.shuffle(_random);
      final discovery = DiscoverEngine.pickFresh(
        results.first,
        exclude: {...excluded, ...familiar.map((t) => t.id)},
        // Los artistas de la parte reconocible tampoco: ya salen ahí.
        excludeArtists: {..._seeds, ...targets.map((a) => a.id)},
        random: _random,
      );
      out.addAll(DiscoverEngine.interleaveHalfAndHalf(familiar, discovery));
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
