import 'dart:math' as math;

class CandidateVideo {
  final String videoId;
  final String title;
  final String author;
  final int? durationSec;
  final int score;
  final bool artistConfirmed;

  /// El candidato viene de una fuente que, por construcción, solo contiene
  /// masters oficiales: un canal `- Topic` (auto-generado por YouTube a
  /// partir del master entregado por el sello), un canal VEVO, o la búsqueda
  /// de canciones de YouTube Music. Ver [YtSearchMatcher.channelAuthorityBonus].
  final bool authoritativeSource;

  const CandidateVideo({
    required this.videoId,
    required this.title,
    required this.author,
    this.durationSec,
    required this.score,
    required this.artistConfirmed,
    this.authoritativeSource = false,
  });
}

class YtSearchMatcher {
  static const _badTerms = [
    'cover',
    'karaoke',
    'instrumental',
    'choreography',
    'coreografia',
    'tutorial',
    'reaction',
    'reaccion',
    'remix',
    'teaser',
    'trailer',
    'live',
    'en vivo',
    'ao vivo',
    'sped up',
    'slowed',
    'nightcore',
    '8d',
    'bass boosted',
    'mashup',
    'full album',
    '1 hour',
    'tribute',
    'tributo',
    // Uploads que son la base sin voz. No siempre lo dicen en el título
    // (ver el caso "Ladders"), pero cuando lo dicen hay que descartarlos.
    'backing track',
    'no vocals',
    'without vocals',
    'vocals only',
    'acapella',
    'a capella',
    'minus one',
    'sin voz',
    'sin voces',
  ];

  static const _goodTerms = [
    'official',
    'audio',
    'lyric',
    'lyrics',
    'mv',
    'm/v',
  ];

  /// C3: señal de canal — "VEVO" y "- Topic" (masters exactos del sello,
  /// auto-generados por YouTube) identifican al uploader, no al título. El
  /// código anterior solo buscaba `vevo` en el título, donde casi nunca
  /// aparece, así que la señal era casi inerte.
  static const _goodChannelTerms = ['vevo', 'topic'];

  /// Peso de la señal de canal autorizado (`- Topic`, VEVO, YouTube Music).
  ///
  /// **Sube de 30 a 120 a propósito** (caso real: "Ladders" de Mac Miller
  /// sonaba en versión instrumental, vídeo `zaas98hALf4`). Ese vídeo se
  /// titula literalmente "Ladders - Mac Miller (Official Audio)", así que
  /// ninguna penalización por palabras clave podía atraparlo: no dice
  /// "instrumental" en ningún lado. Lo que sí lo distingue del master real
  /// es de dónde cuelga — un canal de re-subidas contra
  /// "Mac Miller - Topic".
  ///
  /// Con los pesos viejos el impostor GANABA: se llevaba +30 por "official"
  /// y otros +30 por "audio" (los `_goodTerms` sumaban por cada término
  /// presente), mientras que el master auténtico solo sacaba +30 por el
  /// canal. Es decir, escribir dos palabras de marketing en el título valía
  /// el doble que ser el master del sello. Ahora el canal pesa más que
  /// cualquier otra señal individual (incluida la duración exacta, +100),
  /// porque es la única que un re-subidor no puede falsificar.
  static const int channelAuthorityBonus = 120;

  /// Tope TOTAL del bonus por términos de calidad en el TÍTULO
  /// (`official`, `audio`, `lyrics`…). Antes cada término sumaba +30 por su
  /// cuenta, así que "(Official Audio)" valía +60 — el doble que la señal de
  /// canal. Son texto libre que cualquiera puede escribir, así que valen
  /// como desempate menor, no como evidencia fuerte.
  static const int maxTitleQualityBonus = 30;

  /// C1: mínimo de solapamiento de tokens entre el título esperado (Deezer) y
  /// el título del candidato para que este ni siquiera entre a puntuarse.
  /// Antes `title` se recibía como parámetro pero no se usaba en ninguna
  /// línea: cualquier vídeo del mismo artista con duración parecida puntuaba
  /// igual que el correcto. 50% deja pasar títulos con ruido normal
  /// (artista repetido, "Official Video") pero descarta canciones distintas.
  static const int _minTitleOverlapPct = 50;

  /// Umbral de título para el pase **relajado** (ver `relaxed` en
  /// `_rankCandidates`). Más alto que el estricto a propósito: cuando no hay
  /// corroboración de duración ni de artista, el título tiene que cargar solo
  /// con toda la evidencia, así que se exige más solapamiento, no menos.
  static const int _relaxedTitleOverlapPct = 70;

  /// C8: tolerancia de duración para considerarla "en rango" a efectos del
  /// umbral final de aceptación (ver `_rankCandidates`).
  static const int _durationToleranceSec = 20;

  /// Tope de desfase de duración en el pase relajado. Ahí no se *exige*
  /// corroboración por duración (a menudo la búsqueda ni la trae), pero si
  /// ambas duraciones se conocen y difieren más que esto, es evidencia
  /// suficiente de que es otra canción — no un upload distinto de la misma.
  /// Caso real: un tema homónimo de otro artista, 220s contra ~166s
  /// esperados, se colaba porque el relajado ignoraba la duración del todo.
  static const int _relaxedMaxDurationDiffSec = 30;

  static const Map<String, String> _diacriticsFold = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a', 'ă': 'a', 'ą': 'a',
    'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ĕ': 'e', 'ė': 'e', 'ę': 'e', 'ě': 'e',
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ĩ': 'i', 'ī': 'i', 'ĭ': 'i', 'į': 'i',
    'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o', 'ŏ': 'o', 'ő': 'o',
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ũ': 'u', 'ū': 'u', 'ŭ': 'u', 'ů': 'u', 'ű': 'u', 'ų': 'u',
    'ý': 'y', 'ÿ': 'y', 'ŷ': 'y',
    'ñ': 'n', 'ń': 'n', 'ņ': 'n', 'ň': 'n',
    'ç': 'c', 'ć': 'c', 'ĉ': 'c', 'ċ': 'c', 'č': 'c',
    'ł': 'l', 'ĺ': 'l', 'ľ': 'l',
    'ś': 's', 'ŝ': 's', 'ş': 's', 'š': 's',
    'ź': 'z', 'ż': 'z', 'ž': 'z',
  };

  // C7: `norm()` original borraba cualquier carácter fuera de a-z0-9 (incluido
  // TODO el alfabeto), así que un título coreano/japonés/cirílico quedaba
  // vacío tras normalizar y perdía toda señal de coincidencia. Ahora solo se
  // reemplaza lo que no es letra/número/espacio en ningún alfabeto (`\p{L}`,
  // `\p{N}` Unicode), preservando esos scripts intactos.
  static final RegExp _nonWordChar = RegExp(r'[^\p{L}\p{N}\s]', unicode: true);

  static final RegExp _featSuffix = RegExp(
    r'\s*[\(\[]?\s*-?\s*(feat\.?|featuring|ft\.?|with)\s+.*$',
    caseSensitive: false,
  );

  /// Normaliza texto: minúsculas, diacríticos latinos plegados a su base
  /// ASCII (para que una búsqueda sin tildes siga matcheando), resto de
  /// alfabetos preservado tal cual.
  static String norm(String s) {
    var str = s.toLowerCase();
    str = str.replaceAll('ß', 'ss').replaceAll('œ', 'oe').replaceAll('æ', 'ae');

    final buffer = StringBuffer();
    for (final rune in str.runes) {
      final ch = String.fromCharCode(rune);
      buffer.write(_diacriticsFold[ch] ?? ch);
    }
    str = buffer.toString();

    str = str.replaceAll(_nonWordChar, ' ');
    return str.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static List<String> _tokens(String normalized) =>
      normalized.isEmpty ? const <String>[] : normalized.split(' ');

  /// Título "núcleo" sin el colaborador — un upload de YouTube casi nunca
  /// repite "(feat. X)" en el título aunque sí sea la canción correcta, así
  /// que exigir esos tokens en `_titleOverlap` rechazaría matches legítimos.
  static String _coreTitle(String title) => title.replaceAll(_featSuffix, '').trim();

  /// `needle` (ya normalizado) aparece en `haystack` (ya normalizado) como
  /// palabra o frase completa, no como substring suelto — evita falsos
  /// positivos tipo "Undercover Martyn"/"Coverdale"/"Chain Reaction" al
  /// buscar "cover"/"live"/"reaction".
  static bool _containsPhrase(String haystackNorm, String needleNorm) {
    if (needleNorm.isEmpty) return false;
    final pattern = RegExp('(?<![a-z0-9])${RegExp.escape(needleNorm)}(?![a-z0-9])');
    return pattern.hasMatch(haystackNorm);
  }

  // Los términos se normalizan una sola vez con la misma función que el
  // texto contra el que se comparan — así "m/v" (que `norm()` convierte en
  // "m v", dos tokens) matchea igual que el título candidato, en vez de
  // quedar como código inerte buscando una barra que ya no existe.
  static final List<String> _normBadTerms = _badTerms.map(norm).toList();
  static final List<String> _normGoodTerms = _goodTerms.map(norm).toList();
  static final List<String> _normGoodChannelTerms = _goodChannelTerms.map(norm).toList();

  /// C1: 0..100, cuánto del título esperado (Deezer, sin el sufijo de feat)
  /// aparece como tokens completos en el título del candidato. Solo mide
  /// recall (no penaliza que el candidato tenga texto de más, como el nombre
  /// del canal repetido) — eso es ruido normal de YouTube, no una señal de
  /// canción equivocada.
  static double _titleOverlap(String expectedTitle, String candidateTitleNorm) {
    final expectedTokens = _tokens(norm(_coreTitle(expectedTitle))).toSet();
    if (expectedTokens.isEmpty) return 100;
    final candidateTokens = _tokens(candidateTitleNorm).toSet();
    final matched = expectedTokens.where(candidateTokens.contains).length;
    return 100 * matched / expectedTokens.length;
  }

  /// C3: coincidencia por artista INDIVIDUAL, no por la cadena completa de
  /// colaboradores unida con comas (`DeezerTrack.artistName` la une así, y esa
  /// cadena completa no existe tal cual en ningún canal ni título real). Basta
  /// con que UNO de los colaboradores aparezca. También cubre canales VEVO
  /// donde el nombre va pegado sin espacios ("taylorswiftvevo").
  static bool _artistConfirmed(String artistField, String normAuthor, String normTitle) {
    if (artistField.trim().isEmpty) return false;
    final normAuthorNoSpace = normAuthor.replaceAll(' ', '');
    for (final rawName in artistField.split(',')) {
      final normName = norm(rawName);
      if (normName.isEmpty) continue;
      if (normAuthorNoSpace.contains(normName.replaceAll(' ', ''))) return true;
      if (_containsPhrase(normTitle, normName)) return true;
    }
    return false;
  }

  static List<CandidateVideo> _rankCandidates(
    List<Map<String, dynamic>> candidates, {
    required String artist,
    required String title,
    int? durationSec,
    bool relaxed = false,
  }) {
    if (candidates.isEmpty) return const [];

    final normExpectedTitle = norm(title);
    final scored = <CandidateVideo>[];

    for (var index = 0; index < candidates.length; index++) {
      final raw = candidates[index];
      final vId = raw['videoId'] as String?;
      if (vId == null || vId.isEmpty) continue;

      final rawTitle = (raw['title'] as String?) ?? '';
      final rawAuthor = (raw['author'] as String?) ?? '';
      // C7: cast inseguro — el motor JS puede entregar el número como double
      // y `as int?` lanza en vez de devolver null, rompiendo el bucle.
      final candidateDuration = (raw['durationSec'] as num?)?.toInt();

      final normTitle = norm(rawTitle);
      final normAuthor = norm(rawAuthor);

      // C1: requisito de aceptación, no un simple sumando.
      final titleOverlap = _titleOverlap(title, normTitle);
      if (titleOverlap < (relaxed ? _relaxedTitleOverlapPct : _minTitleOverlapPct)) continue;

      final artistConfirmed = _artistConfirmed(artist, normAuthor, normTitle);

      int score = (titleOverlap * 0.6).round();

      // 1. Comparación de duración si se conoce. C7: `durationSec == 0` (el
      // fallback `?? 0` cuando Deezer no trae duración) no debe tratarse como
      // "duración esperada real" — antes solo se comprobaba que la del
      // candidato fuera > 0, así que una pista sin duración conocida penalizaba
      // -50 a TODOS los candidatos.
      bool durationOk = false;
      bool durationWildlyOff = false;
      if (durationSec != null && durationSec > 0 && candidateDuration != null && candidateDuration > 0) {
        final diff = (candidateDuration - durationSec).abs();
        durationOk = diff <= _durationToleranceSec;
        durationWildlyOff = diff > _relaxedMaxDurationDiffSec;
        if (diff <= 3) {
          score += 100;
        } else if (diff <= 10) {
          score += 40;
        } else if (diff <= 20) {
          score += 15;
        } else if (diff > 30) {
          score -= 50;
        }
      }

      // C8: evidencia positiva — además del título, se exige duración en
      // rango O artista confirmado. Reemplaza el viejo umbral `maxScore >= 0`
      // (permisivo y estricto a la vez: aceptaba cualquier candidato sin
      // penalizaciones porque el bonus de posición siempre sumaba algo, y
      // rechazaba remixes/directos legítimos por acumular penalizaciones).
      //
      // En el pase relajado esta corroboración no se exige: es el último
      // recurso antes de no reproducir nada (ver C12), y ahí la alternativa
      // no es "sonar la canción correcta" sino "no sonar y saltar de pista".
      // Pero "no exigir duración" no es lo mismo que "ignorar la duración":
      // si ambas se conocen y difieren demasiado, es otra canción (C13).
      if (relaxed && durationWildlyOff) continue;
      if (!relaxed && !durationOk && !artistConfirmed) continue;

      // 2. Términos indeseados — DESCALIFICAN el candidato de plano, no
      // restan puntos. Un simple -80 puede quedar absorbido por duración
      // exacta (+100) + artista confirmado (+50) + bonus de posición y
      // terminar aceptando un karaoke/cover de todos modos (justo el riesgo
      // que señala el plan: "con N=5 el mismo karaoke sería aceptado"). Como
      // ahora es descalificación en vez de puntaje, "tope de una sola
      // penalización" queda resuelto de forma trivial (antes "Karaoke Cover"
      // acumulaba -160 vía dos términos). Condicional al título original
      // (C4): si la pista de origen ya es, por ejemplo, "Live", ese término
      // no es señal de nada (todos los candidatos lo compartirían por igual)
      // y no debe descalificar. Límites de palabra/frase evitan falsos
      // positivos ("Undercover Martyn", "Coverdale", "Chain Reaction",
      // "Trailer Trash").
      final isBadMatch = _normBadTerms.any((bad) =>
          !_containsPhrase(normExpectedTitle, bad) &&
          (_containsPhrase(normTitle, bad) || _containsPhrase(normAuthor, bad)));
      if (isBadMatch) continue;

      // 3. Bonificación por términos de calidad del título, ACOTADA a
      // [maxTitleQualityBonus] en total. Sumar por cada término presente
      // hacía que "(Official Audio)" (+60) pesara más que ser el master del
      // sello (+30), que es justo lo que dejó sonar un instrumental
      // re-subido por encima del original.
      if (_normGoodTerms.any((good) => _containsPhrase(normTitle, good))) {
        score += maxTitleQualityBonus;
      }

      // C3: señal de canal — "VEVO"/"- Topic" identifican al uploader, se
      // busca en el autor, no en el título (donde antes "vevo" era casi
      // inerte porque casi nunca aparece ahí). Un resultado que viene de la
      // búsqueda de canciones de YouTube Music (`source: 'ytmusic'`) cuenta
      // igual: ese catálogo son masters oficiales por construcción, y ahí el
      // autor llega como nombre de artista, sin el sufijo "- Topic".
      final fromYtMusic = (raw['source'] as String?) == 'ytmusic';
      final authoritative = fromYtMusic ||
          _normGoodChannelTerms.any((good) => _containsPhrase(normAuthor, good));
      if (authoritative) score += channelAuthorityBonus;

      // 4. Coincidencia de artista confirmada (ver arriba).
      if (artistConfirmed) score += 50;

      // 5. Bonus de posición de relevancia de YouTube, acotado (C2) — antes
      // escalaba con `candidates.length` (`(candidates.length - index) * 2`),
      // así que en la ruta de fallback (30-60 candidatos) el primero recibía
      // +60 a +120, más que un match exacto de duración (+100).
      score += math.max(0, 10 - index);

      scored.add(CandidateVideo(
        videoId: vId,
        title: rawTitle,
        author: rawAuthor,
        durationSec: candidateDuration,
        score: score,
        artistConfirmed: artistConfirmed,
        authoritativeSource: authoritative,
      ));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored;
  }

  /// Evalúa la lista de candidatos devueltos por Innertube search y devuelve
  /// el de mejor puntuación, o `null` si ninguno pasa el umbral de aceptación
  /// (título + duración-o-artista, ver `_rankCandidates`).
  static CandidateVideo? pickBest(
    List<Map<String, dynamic>> candidates, {
    required String artist,
    required String title,
    int? durationSec,
    bool relaxed = false,
  }) {
    final ranked = _rankCandidates(
      candidates,
      artist: artist,
      title: title,
      durationSec: durationSec,
      relaxed: relaxed,
    );
    return ranked.isEmpty ? null : ranked.first;
  }

  /// C6: top-[topN] candidatos que ya superaron el umbral de aceptación, para
  /// poder probar el siguiente si la extracción real del primero falla
  /// (vídeo privado/geobloqueado/age-gate) en vez de rendirse de inmediato.
  ///
  /// Con [relaxed] en `true` se aplica el pase de último recurso (C12): se
  /// exige más solapamiento de título pero se deja de exigir corroboración
  /// por duración o artista. Los términos indeseados (karaoke/cover/live…)
  /// **siguen descalificando** igual que en el pase estricto — relajar el
  /// umbral no debe llegar nunca al punto de reproducir un karaoke.
  static List<CandidateVideo> pickTopCandidates(
    List<Map<String, dynamic>> candidates, {
    required String artist,
    required String title,
    int? durationSec,
    int topN = 3,
    bool relaxed = false,
  }) {
    return _rankCandidates(
      candidates,
      artist: artist,
      title: title,
      durationSec: durationSec,
      relaxed: relaxed,
    ).take(topN).toList();
  }
}
