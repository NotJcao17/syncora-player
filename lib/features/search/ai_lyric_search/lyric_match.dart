/// Comprueba si un fragmento que el usuario recuerda aparece en una letra
/// real (2026-10-08). La IA propone candidatos; esto confirma con la letra de
/// LRCLib cuáles contienen de verdad el fragmento, para mostrarlos primero.
///
/// Tolerante a lo que la gente escribe de memoria: sin acentos ni
/// puntuación, y por pares de palabras consecutivas en vez de exigir la frase
/// entera literal (una palabra cambiada u omitida no la descarta).
class LyricMatch {
  LyricMatch._();

  /// Fracción de pares de palabras consecutivas del fragmento que aparecen en
  /// la letra, de 0 a 1. Con una sola palabra, 1 si aparece y 0 si no.
  static double score(String fragment, String lyrics) {
    final f = _words(fragment);
    if (f.isEmpty) return 0;
    final text = ' ${_words(lyrics).join(' ')} ';
    if (text.trim().isEmpty) return 0;
    if (text.contains(' ${f.join(' ')} ')) return 1;
    if (f.length == 1) return text.contains(' ${f.first} ') ? 1 : 0;

    var hits = 0;
    for (var i = 0; i < f.length - 1; i++) {
      if (text.contains(' ${f[i]} ${f[i + 1]} ')) hits++;
    }
    return hits / (f.length - 1);
  }

  /// Umbral para dar la letra por confirmada.
  static const double confirmedThreshold = 0.5;

  static bool isConfirmed(String fragment, String lyrics) => score(fragment, lyrics) >= confirmedThreshold;

  static const _accents = {
    'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ã': 'a',
    'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
    'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i',
    'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', 'õ': 'o',
    'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
    'ñ': 'n', 'ç': 'c',
  };

  static List<String> _words(String s) {
    var out = s.toLowerCase();
    _accents.forEach((k, v) => out = out.replaceAll(k, v));
    // Contracciones ("don't" = "dont") y marcas de tiempo de LRC ("[01:02.33]").
    out = out.replaceAll(RegExp(r"['’`´]"), '').replaceAll(RegExp(r'\[\d+:\d+(\.\d+)?\]'), ' ');
    return out.split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty).toList();
  }
}
