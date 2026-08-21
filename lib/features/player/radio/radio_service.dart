import 'dart:math' as math;

import '../../../data/apis/deezer_api.dart';
import '../../../data/models/deezer/deezer_artist.dart';
import '../../../data/models/deezer/deezer_track.dart';
import '../../search/search_ranking.dart';
import '../player_models.dart';

/// Radio / cola infinita sobre endpoints de Deezer (Fase 7.B, D-10 —
/// activada por defecto, sin IA, sin gastar presupuesto de Gemini).
///
/// Sigue el precedente de `SearchRanking`
/// (`lib/features/search/search_ranking.dart`): la mayor parte de la lógica
/// vive en métodos estáticos **puros** (sin I/O), testeables directamente
/// contra fixtures JSON en `test/fixtures/deezer_radio/` sin mockear
/// Dio/`DeezerApi` (no hay precedente de eso en el proyecto). Solo
/// [generateBatch] hace I/O real, de forma más delgada y sin cobertura
/// exhaustiva — igual que `DeezerApi` mismo no tiene tests hoy.
class RadioService {
  RadioService({DeezerApi? deezerApi, math.Random? random})
      : _deezerApi = deezerApi,
        _random = random ?? math.Random();

  final DeezerApi? _deezerApi;
  final math.Random _random;

  /// Artistas semilla por disparo (parámetro acordado en el plan).
  static const int seedCount = 5;

  /// Canciones a tomar de cada `/artist/{id}/radio` en el camino normal (no
  /// toda la lista que devuelve el endpoint).
  static const int tracksPerArtistSeed = 5;

  /// Lote objetivo de canciones válidas por disparo.
  static const int targetBatchSize = 25;

  // --------------------------------------------------------------------
  // Funciones puras
  // --------------------------------------------------------------------

  /// Cuenta cuántas veces aparece cada artista (por `artistId` principal) en
  /// [contextTracks] — el contexto activo (`originalContextTracks` del
  /// estado del reproductor). Pistas sin `artistId` identificable (`null` o
  /// `<= 0`) se ignoran: no pueden servir de semilla de radio.
  static Map<int, int> countArtistFrequency(List<SyncoraTrack> contextTracks) {
    final frequency = <int, int>{};
    for (final track in contextTracks) {
      final artistId = track.artistId;
      if (artistId == null || artistId <= 0) continue;
      frequency[artistId] = (frequency[artistId] ?? 0) + 1;
    }
    return frequency;
  }

  /// Muestreo aleatorio ponderado por frecuencia, SIN reemplazo, de hasta
  /// [count] artistas de [frequency] (id de artista -> nº de apariciones).
  ///
  /// Determinista dado un [random] con semilla fija: útil para tests
  /// estadísticos (repetir con varias semillas y contar cuántas veces sale
  /// elegido cada artista). Nunca usa `Random()` sin parámetro internamente
  /// — el llamador siempre lo inyecta.
  ///
  /// El orden de iteración de [frequency] (un `Map` literal es un
  /// `LinkedHashMap`, orden de inserción) determina el orden de desempate
  /// cuando el peso acumulado cae exactamente en un límite, así que el
  /// resultado es reproducible mientras el llamador construya el mapa de
  /// forma determinista (como hace [countArtistFrequency], que itera
  /// [contextTracks] en orden).
  static List<int> weightedSampleArtists(
    Map<int, int> frequency,
    int count,
    math.Random random,
  ) {
    if (frequency.isEmpty || count <= 0) return const [];

    final pool = Map<int, int>.from(frequency);
    final result = <int>[];
    final n = math.min(count, pool.length);

    for (var i = 0; i < n; i++) {
      final totalWeight = pool.values.fold<int>(0, (sum, w) => sum + w);
      if (totalWeight <= 0) break;

      var target = random.nextInt(totalWeight);
      int? chosen;
      for (final entry in pool.entries) {
        target -= entry.value;
        if (target < 0) {
          chosen = entry.key;
          break;
        }
      }
      chosen ??= pool.keys.first; // red de seguridad, no debería alcanzarse

      result.add(chosen);
      pool.remove(chosen);
    }

    return result;
  }

  /// Completa [currentSeeds] hasta [target] artistas usando candidatos de
  /// [relatedPool] (artistas relacionados ya obtenidos por I/O, en el orden
  /// en que vienen de Deezer), evitando duplicar cualquier id ya presente en
  /// [currentSeeds] o en [excludeArtistIds] (ej. artistas del contexto que
  /// no fueron elegidos como semilla, pero tampoco tiene sentido re-sembrar).
  /// Pura: no hace I/O, solo combina listas ya resueltas.
  ///
  /// Cubre los casos límite de variedad de artistas del plan (7.B.4):
  /// - 1 solo artista: [currentSeeds] trae 1, se completa con sus propios
  ///   relacionados.
  /// - 2-4 artistas: se completa con los relacionados de los que hay.
  /// - Si [relatedPool] no alcanza para llegar a [target], devuelve menos de
  ///   [target] semillas sin fallar — el llamador sigue con lo que haya.
  static List<int> completeSeeds({
    required List<int> currentSeeds,
    required List<DeezerArtist> relatedPool,
    Set<int> excludeArtistIds = const {},
    int target = seedCount,
  }) {
    final seeds = List<int>.from(currentSeeds);
    final seedSet = seeds.toSet();

    for (final artist in relatedPool) {
      if (seeds.length >= target) break;
      if (seedSet.contains(artist.id)) continue;
      if (excludeArtistIds.contains(artist.id)) continue;
      seeds.add(artist.id);
      seedSet.add(artist.id);
    }

    return seeds;
  }

  /// Pipeline "dirigido por cuota": filtra [candidates] por
  /// `SearchRanking.isPopularTrack` (mismo umbral que "búsqueda popular", no
  /// se reimplementa), deduplica por id (los ids repetidos entre `/radio` de
  /// distintos artistas o entre `/radio` y `/related` no deben aparecer dos
  /// veces), excluye cualquier id presente en [excludeIds] (cola actual,
  /// contexto de origen, pista actual — comparados como String porque así
  /// vienen los ids de `SyncoraTrack`), y recorta a [targetCount].
  ///
  /// Soporta "pedir con buffer": si [candidates] trae de sobra, solo toma
  /// los primeros [targetCount] válidos tras filtrar/deduplicar; si trae de
  /// menos, simplemente devuelve menos de [targetCount] sin fallar.
  static List<DeezerTrack> filterDedupQuota({
    required List<DeezerTrack> candidates,
    required Set<String> excludeIds,
    int targetCount = targetBatchSize,
  }) {
    final result = <DeezerTrack>[];
    final seenIds = <int>{};

    for (final track in candidates) {
      if (result.length >= targetCount) break;
      if (!seenIds.add(track.id)) continue; // duplicado dentro del pool
      if (excludeIds.contains(track.id.toString())) continue;
      if (!SearchRanking.isPopularTrack(track)) continue;
      result.add(track);
    }

    return result;
  }

  // --------------------------------------------------------------------
  // Orquestación con I/O
  // --------------------------------------------------------------------

  /// Genera un lote de hasta [targetBatchSize] pistas de radio a partir del
  /// contexto activo ([contextTracks], típicamente
  /// `SyncoraPlayerState.originalContextTracks`), excluyendo cualquier
  /// pista cuyo id esté en [excludeIds].
  ///
  /// Flujo (7.B.2/7.B.3/7.B.4 del plan):
  /// 1. Cuenta frecuencia de artistas en el contexto.
  /// 2. Si no hay ningún artista identificable (contexto vacío o sin
  ///    `artistId`), cae a [DeezerApi.getTopCharts] (7.B.4, caso "cola
  ///    vacía").
  /// 3. Muestrea hasta 5 semillas ponderadas por frecuencia.
  /// 4. Si hay menos de 5 artistas distintos, completa semillas con
  ///    `/artist/{id}/related` de las ya elegidas (cubre 1 artista y 2-4
  ///    artistas, 7.B.4) — sin fallar si no alcanza para llegar a 5.
  /// 5. Pide `/artist/{id}/radio` de cada semilla EN PARALELO
  ///    (`Future.wait`, mismo patrón que `_enrichAmbiguousTitles` en
  ///    `deezer_api.dart`).
  /// 6. Pasa el pool combinado por el pipeline puro
  ///    ([filterDedupQuota]). Si no alcanza el objetivo, reintenta con la
  ///    lista completa de cada radio (no solo los primeros ~5) antes de
  ///    rendirse — "pedir con buffer" (7.B.3). Como [DeezerApi] cachea por
  ///    artista, este reintento no repite peticiones de red ya hechas.
  /// 7. Si aun así no hay nada, cae a `getTopCharts` como último recurso.
  ///
  /// Cualquier error de red se traga silenciosamente en cada paso (el
  /// llamador — `SyncoraPlayerController._fetchRadioBatch` — ya envuelve
  /// todo en su propio try/catch, pero este método no debe lanzar por un
  /// solo artista fallido dentro de un `Future.wait`).
  Future<List<SyncoraTrack>> generateBatch({
    required List<SyncoraTrack> contextTracks,
    required Set<String> excludeIds,
  }) async {
    final api = _deezerApi;
    if (api == null) return const [];

    final frequency = countArtistFrequency(contextTracks);

    if (frequency.isEmpty) {
      return _fallbackToCharts(api, excludeIds);
    }

    final distinctArtistIds = frequency.keys.toList();
    var seeds = weightedSampleArtists(
      frequency,
      math.min(seedCount, distinctArtistIds.length),
      _random,
    );

    if (seeds.length < seedCount) {
      final relatedPool = await _fetchRelatedForAll(api, seeds);
      seeds = completeSeeds(
        currentSeeds: seeds,
        relatedPool: relatedPool,
        excludeArtistIds: distinctArtistIds.toSet(),
      );
    }

    if (seeds.isEmpty) {
      return _fallbackToCharts(api, excludeIds);
    }

    final trimmedPool = await _fetchRadioForAll(api, seeds, limitPerArtist: tracksPerArtistSeed);
    var filtered = filterDedupQuota(candidates: trimmedPool, excludeIds: excludeIds);

    if (filtered.length < targetBatchSize) {
      // Buffer: reintentar con la lista completa de cada radio (ya
      // cacheada por DeezerApi, no repite la petición de red) antes de
      // rendirse con un lote corto.
      final fullPool = await _fetchRadioForAll(api, seeds, limitPerArtist: null);
      filtered = filterDedupQuota(candidates: fullPool, excludeIds: excludeIds);
    }

    if (filtered.isEmpty) {
      return _fallbackToCharts(api, excludeIds);
    }

    return filtered.map((t) => t.toSyncoraTrack()).toList();
  }

  Future<List<SyncoraTrack>> _fallbackToCharts(DeezerApi api, Set<String> excludeIds) async {
    try {
      final charts = await api.getTopCharts();
      final filtered = filterDedupQuota(candidates: charts, excludeIds: excludeIds);
      return filtered.map((t) => t.toSyncoraTrack()).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<DeezerArtist>> _fetchRelatedForAll(DeezerApi api, List<int> artistIds) async {
    final lists = await Future.wait(artistIds.map((id) async {
      try {
        return await api.getArtistRelated(id);
      } catch (_) {
        return const <DeezerArtist>[];
      }
    }));
    return [for (final list in lists) ...list];
  }

  Future<List<DeezerTrack>> _fetchRadioForAll(
    DeezerApi api,
    List<int> artistIds, {
    required int? limitPerArtist,
  }) async {
    final lists = await Future.wait(artistIds.map((id) async {
      try {
        final tracks = await api.getArtistRadio(id);
        return limitPerArtist != null ? tracks.take(limitPerArtist).toList() : tracks;
      } catch (_) {
        return const <DeezerTrack>[];
      }
    }));
    // Round-robin, no concatenado en bloques (revisión de 7.B, bug #4): si
    // se concatenara `[...lista1, ...lista2, ...]`, `filterDedupQuota`
    // ("los primeros N válidos") dejaba que la primera semilla dominara casi
    // todo el lote de 25 en cuanto aportaba suficientes candidatos válidos
    // por sí sola — verificado con las fixtures reales del repo, donde una
    // sola exclusión ya alcanzaba para que un artista aportara 20 de 25.
    return interleaveRoundRobin(lists);
  }

  /// Combina listas por artista en orden round-robin (una pista de cada
  /// lista por turno, en vez de concatenar en bloques) — así el pipeline de
  /// cuota ([filterDedupQuota], que toma "los primeros N válidos" en el
  /// orden recibido) reparte el lote entre TODAS las semillas en vez de
  /// dejar que la primera agote el cupo. Pura: no hace I/O.
  static List<DeezerTrack> interleaveRoundRobin(List<List<DeezerTrack>> perArtistLists) {
    final result = <DeezerTrack>[];
    var maxLen = 0;
    for (final list in perArtistLists) {
      if (list.length > maxLen) maxLen = list.length;
    }
    for (var i = 0; i < maxLen; i++) {
      for (final list in perArtistLists) {
        if (i < list.length) result.add(list[i]);
      }
    }
    return result;
  }
}
