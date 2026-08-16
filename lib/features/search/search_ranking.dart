import 'dart:math' as math;

import '../../data/models/deezer/deezer_artist.dart';
import '../../data/models/deezer/deezer_track.dart';

/// Ranking del buscador: combina relevancia de texto con popularidad.
///
/// Diseño (ver docs/plan_buscador_importacion_matcher.md, sección "Decisiones de
/// diseño tomadas"): NO se usan tiers estrictos ("el texto manda siempre") porque
/// eso hace perder resultados populares reales contra coincidencias exactas
/// irrelevantes (ej. "uptown" devolvía "Bex - Uptown" antes que "Uptown Funk").
/// En vez de eso, texto y popularidad se sopesan en la misma escala.
class SearchRanking {
  SearchRanking._();

  /// Normaliza para comparar: minúsculas, sin diacríticos, sin apóstrofes
  /// (se eliminan, no se convierten en espacio — así "god's" y "gods" matchean),
  /// resto de puntuación colapsada a espacio.
  static String normalize(String input) {
    var s = input.toLowerCase();
    s = s.replaceAll(RegExp(r"['’`´]"), '');

    const withDiacritics = 'àáâãäåèéêëìíîïòóôõöùúûüýÿñç';
    const withoutDiacritics = 'aaaaaaeeeeiiiioooooouuuuyync';
    for (var i = 0; i < withDiacritics.length; i++) {
      s = s.replaceAll(withDiacritics[i], withoutDiacritics[i]);
    }

    s = s.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  static List<String> _tokens(String normalized) =>
      normalized.isEmpty ? const <String>[] : normalized.split(' ');

  static final RegExp _parentheticalSuffix = RegExp(r'\s*[\(\[][^)\]]*[\)\]]');
  // "feat"/"featuring"/"with" a veces aparece sin guion ni paréntesis
  // (ej. título real de Deezer: "Guess featuring billie eilish").
  static final RegExp _featSuffix = RegExp(
    r'\s*-?\s*(feat\.?|featuring|with)\s+.*$',
    caseSensitive: false,
  );
  static final RegExp _otherDashSuffix = RegExp(
    r'\s*-\s*(remix|live|acoustic|version|remaster(ed)?|radio edit|single version).*$',
    caseSensitive: false,
  );

  /// Título "base" para agrupar variantes del mismo tema (ej. "3 A.M." y
  /// "3 A.M. (feat. Tommy Torres)" deben agruparse bajo la misma base) —
  /// usado para detectar títulos ambiguos que necesitan enriquecerse con
  /// `/track/{id}` para mostrar quién colabora (A5 del plan).
  static String baseTitle(String title) {
    var t = title.replaceAll(_parentheticalSuffix, '');
    t = t.replaceAll(_featSuffix, '');
    t = t.replaceAll(_otherDashSuffix, '');
    return normalize(t);
  }

  /// Un token de query "cubre" un token del resultado si son iguales o si el
  /// token del resultado empieza con el token de query — así una query
  /// incompleta mientras se teclea ("arian", "uptow") sigue matcheando la
  /// palabra completa ("ariana", "uptown"). Es estrictamente más permisivo
  /// que la igualdad exacta (nunca reduce un match que ya existía).
  static bool _covers(String queryToken, String resultToken) =>
      resultToken.startsWith(queryToken);

  /// Similitud de texto 0..100 entre `query` y un resultado (título + artista).
  ///
  /// No es un simple "contiene todas las palabras": eso premiaba títulos largos
  /// que casualmente contenían el query completo (ej. un cover con nombre
  /// "Rumour Has It / Someone Like You (Cover of Adele)" ganaba sobre la Adele
  /// real). Se combina:
  ///   - recall: cuánto del query se encuentra en (título ∪ artista)
  ///   - precision: qué fracción del título es realmente relevante al query
  /// para que títulos con mucho "relleno" no calificado por el query pierdan
  /// precisión aunque contengan todas las palabras buscadas.
  static double textScore(String query, {required String title, String artist = ''}) {
    final qSet = _tokens(normalize(query)).toSet();
    if (qSet.isEmpty) return 0;

    final titleTokens = _tokens(normalize(title));
    final artistTokens = _tokens(normalize(artist));
    final titleSet = titleTokens.toSet();
    final unionSet = {...titleSet, ...artistTokens};

    final matchedQueryTokens = qSet.where((q) => unionSet.any((t) => _covers(q, t))).length;
    final recall = matchedQueryTokens / qSet.length;

    final matchedInTitle = titleTokens.where((t) => qSet.any((q) => _covers(q, t))).length;
    final precision = titleTokens.isEmpty ? 0.0 : matchedInTitle / titleTokens.length;

    return 100 * (0.6 * recall + 0.4 * precision);
  }

  /// Popularidad de una pista (0..100) a partir de su `rank` de Deezer (0..~1M).
  static double popScoreFromRank(int? rank) {
    if (rank == null || rank <= 0) return 0;
    return (rank / 10000).clamp(0, 100).toDouble();
  }

  /// Bonus de popularidad de artista (0..40) a partir de `nb_fan`, en escala
  /// logarítmica: un artista con 15M fans no debe pesar 15,000x más que uno con
  /// 1,000 — solo lo suficiente para desempatar a favor del más conocido.
  static double fanBonus(int nbFan) {
    if (nbFan <= 0) return 0;
    // log10(15_400_000) ≈ 7.19 -> normalizado a ~40 (fan count de un superstar global)
    final v = (math.log(nbFan + 1) / math.ln10) / 7.19 * 40;
    return v.clamp(0, 40).toDouble();
  }

  /// Similitud de texto para nombres de ARTISTA (no de títulos). A diferencia de
  /// un título, un nombre de artista con más palabras no es "menos relevante" —
  /// "Bruno Mars" no es peor match que "Bruno" a secas para la query "bruno".
  /// Por eso NO se usa el término de precisión de [textScore] aquí (penalizaría
  /// a cualquier artista real cuyo nombre completo tenga más de una palabra),
  /// solo recall + un bonus pequeño por coincidencia exacta.
  ///
  /// Se detectó probando contra datos reales: con la fórmula de [textScore],
  /// la query "bruno" hacía ganar a un artista literalmente llamado "Bruno"
  /// (12 mil fans) por encima de Bruno Mars (12.7M fans) — el término de
  /// precisión penalizaba a "Bruno Mars" por tener una palabra "de más".
  ///
  /// El recall usa [_covers] (match por prefijo, no igualdad exacta): sin
  /// esto, una query a medio teclear como "arian" o "bruno m" no matcheaba
  /// ningún token del nombre completo ("ariana", "mars") y el artista real
  /// quedaba fuera de `minRelevance` por completo — confirmado contra la API
  /// en vivo, donde Deezer sí devuelve a Ariana Grande/Bruno Mars entre los
  /// candidatos, pero nuestro score los descartaba antes de llegar a la UI.
  static double artistTextScore(String query, String name) {
    final qSet = _tokens(normalize(query)).toSet();
    if (qSet.isEmpty) return 0;
    final nameSet = _tokens(normalize(name)).toSet();
    final matched = qSet.where((q) => nameSet.any((t) => _covers(q, t))).length;
    final recall = matched / qSet.length;
    final exactBonus = normalize(name) == normalize(query) ? 10 : 0;
    return 100 * recall + exactBonus;
  }

  static bool trackMatchesArtist(DeezerTrack track, DeezerArtist artist) {
    if (track.artistId == artist.id) return true;
    return track.contributorsList.any((c) => c.id == artist.id);
  }

  /// Fans mínimos para que un artista se considere "popular" a efectos del
  /// toggle "Popular" del buscador y de [filterArtistsWithPresence] — no
  /// afecta el ranking, solo qué se le muestra al usuario. Calibrado contra
  /// fixtures reales: para queries de un solo artista claro (ej. "adele"),
  /// hay un salto grande entre el artista real (millones de fans) y el resto
  /// (decenas de miles hacia abajo), así que 50k deja pasar artistas
  /// razonablemente conocidos sin abrir la puerta a cuentas de nicho/broma.
  static const int popularArtistMinFans = 50000;

  /// Piso de `popScoreFromRank` para que una canción cuente como "popular"
  /// en el toggle — equivale a un `rank` de Deezer de ~300k (0..1M).
  static const double popularTrackMinScore = 30;

  static bool isPopularArtist(DeezerArtist artist) => artist.nbFan >= popularArtistMinFans;

  static bool isPopularTrack(DeezerTrack track) => popScoreFromRank(track.rank) >= popularTrackMinScore;

  /// Filtra artistas que matchean por nombre en `/search/artist` pero no
  /// tienen ninguna canción real en el pool de tracks ya traído para esta
  /// misma búsqueda (ej. "DJ Despacito" para la query "despacito": 4137 fans,
  /// match exacto de nombre, cero canciones en el pool de 100 — confirmado
  /// contra la API en vivo). Se exceptúan los artistas con fans suficientes
  /// ([popularArtistMinFans]): uno realmente famoso no debe caerse de la
  /// lista solo porque, por azar, su canción no esté en este pool puntual de
  /// 100 resultados. Costo cero: reusa el pool de tracks que la búsqueda
  /// "Todo" ya trae.
  static List<DeezerArtist> filterArtistsWithPresence(
    List<DeezerArtist> artists,
    List<DeezerTrack> tracksPool,
  ) {
    return artists
        .where((a) => isPopularArtist(a) || tracksPool.any((t) => trackMatchesArtist(t, a)))
        .toList();
  }

  /// Ordena artistas por relevancia de texto + popularidad de fans combinadas.
  /// `minRelevance` filtra coincidencias de Deezer demasiado débiles (quorum
  /// difuso) para no mostrarlas nunca, incluso más allá del recorte a 5 que
  /// hace la UI hoy.
  static List<DeezerArtist> rankArtists(
    List<DeezerArtist> artists,
    String query, {
    double minRelevance = 20,
  }) {
    final scored = <_Scored<DeezerArtist>>[];
    for (final a in artists) {
      final ts = artistTextScore(query, a.name);
      if (ts < minRelevance) continue;
      scored.add(_Scored(a, ts + fanBonus(a.nbFan)));
    }
    scored.sort((x, y) => y.score.compareTo(x.score));
    return scored.map((s) => s.value).toList();
  }

  /// El artista dominante de una búsqueda: el mejor resultado de [rankArtists]
  /// (ya viene ordenado), siempre que su score combinado supere un mínimo —
  /// para no promover un artista irrelevante como "dominante" en queries sin
  /// ningún artista claro (ej. "uptown") — Y que tenga al menos una pista en
  /// `tracksPool` (los tracks ya traídos para esta misma búsqueda).
  ///
  /// Ese segundo requisito es un gate anti-falsos-positivos descubierto con
  /// datos reales: para la query "despacito", "DJ Despacito" (una cuenta de
  /// DJ/novedad con pocos fans) pasaba el filtro de score por match exacto de
  /// nombre, pero no tiene ninguna canción entre los resultados de esa
  /// búsqueda — evidencia de que Deezer lo incluyó por relevancia difusa en
  /// `/search/artist`, no porque sea el objetivo real de la búsqueda. Sin este
  /// gate, se dispararía un backfill (+1 petición) y un bonus de popularidad
  /// sobre canciones que no le pertenecen.
  static DeezerArtist? findDominantArtist(
    List<DeezerArtist> rankedArtists,
    String query,
    List<DeezerTrack> tracksPool, {
    double minCombinedScore = 60,
  }) {
    if (rankedArtists.isEmpty) return null;
    final top = rankedArtists.first;
    final combined = artistTextScore(query, top.name) + fanBonus(top.nbFan);
    if (combined < minCombinedScore) return null;
    final hasTrackPresence = tracksPool.any((t) => trackMatchesArtist(t, top));
    if (!hasTrackPresence) return null;
    return top;
  }

  /// Ordena canciones por texto + popularidad + (si aplica) bonus del artista
  /// dominante de la búsqueda.
  static List<DeezerTrack> rankTracks(
    List<DeezerTrack> tracks,
    String query, {
    DeezerArtist? dominantArtist,
  }) {
    final scored = tracks.map((t) {
      final ts = textScore(query, title: t.title, artist: t.artistName);
      final ps = popScoreFromRank(t.rank);
      final bonus = (dominantArtist != null && trackMatchesArtist(t, dominantArtist))
          ? fanBonus(dominantArtist.nbFan)
          : 0.0;
      return _Scored(t, ts + ps + bonus);
    }).toList();
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.map((s) => s.value).toList();
  }
}

class _Scored<T> {
  final T value;
  final double score;
  const _Scored(this.value, this.score);
}
