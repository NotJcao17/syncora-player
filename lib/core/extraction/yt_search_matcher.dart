class CandidateVideo {
  final String videoId;
  final String title;
  final String author;
  final int? durationSec;
  final int score;

  const CandidateVideo({
    required this.videoId,
    required this.title,
    required this.author,
    this.durationSec,
    required this.score,
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
  ];

  static const _goodTerms = [
    'official',
    'audio',
    'lyric',
    'lyrics',
    'mv',
    'vevo',
    'm/v',
  ];

  /// Normaliza texto: minúsculas, elimina acentos/diacríticos y caracteres especiales.
  static String norm(String s) {
    var str = s.toLowerCase();
    const withDiacritics = 'àáâãäåèéêëìíîïòóôõöùúûüýÿñç';
    const withoutDiacritics = 'aaaaaaeeeeiiiiooooouuuuyync';

    for (var i = 0; i < withDiacritics.length; i++) {
      str = str.replaceAll(withDiacritics[i], withoutDiacritics[i]);
    }

    // Reemplazar signos y puntuación por espacios
    return str.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Evalúa la lista de candidatos devueltos por Innertube search
  /// y devuelve el candidato con mejor puntuación (o null si ninguno alcanza el umbral de 0).
  static CandidateVideo? pickBest(
    List<Map<String, dynamic>> candidates, {
    required String artist,
    required String title,
    int? durationSec,
  }) {
    if (candidates.isEmpty) return null;

    final normArtist = norm(artist);

    CandidateVideo? bestCandidate;
    int maxScore = -999999;

    for (var index = 0; index < candidates.length; index++) {
      final raw = candidates[index];
      final vId = raw['videoId'] as String?;
      if (vId == null || vId.isEmpty) continue;

      final rawTitle = (raw['title'] as String?) ?? '';
      final rawAuthor = (raw['author'] as String?) ?? '';
      final candidateDuration = raw['durationSec'] as int?;

      final normTitle = norm(rawTitle);
      final normAuthor = norm(rawAuthor);

      int score = 0;

      // 1. Comparación de duración si se conoce
      if (durationSec != null && candidateDuration != null && candidateDuration > 0) {
        final diff = (candidateDuration - durationSec).abs();
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

      // 2. Penalización por términos indeseados en título o autor
      for (final bad in _badTerms) {
        if (normTitle.contains(bad) || normAuthor.contains(bad)) {
          score -= 80;
        }
      }

      // 3. Bonificación por términos de calidad en título
      for (final good in _goodTerms) {
        if (normTitle.contains(good)) {
          score += 30;
        }
      }

      // 4. Coincidencia del nombre del artista en autor o título
      if (normArtist.isNotEmpty && (normAuthor.contains(normArtist) || normTitle.contains(normArtist))) {
        score += 50;
      }

      // 5. Bonus por posición de relevancia de YouTube (desempate suave)
      score += (candidates.length - index) * 2;

      final candidate = CandidateVideo(
        videoId: vId,
        title: rawTitle,
        author: rawAuthor,
        durationSec: candidateDuration,
        score: score,
      );

      if (score > maxScore) {
        maxScore = score;
        bestCandidate = candidate;
      }
    }

    if (bestCandidate != null && maxScore >= 0) {
      return bestCandidate;
    }

    return null;
  }
}
