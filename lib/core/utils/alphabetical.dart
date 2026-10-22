/// Orden alfabético "humano" para títulos, artistas y álbumes (ronda 10).
///
/// `toLowerCase().compareTo` compara puntos de código: "Él", "Ángel" o
/// "¿Qué?" quedaban después de la "z" porque `é`, `á` y `¿` están más allá
/// del ASCII. Aquí se comparan sin acentos ni signos iniciales, y solo si
/// empatan se desempata por el texto original (así "nino" va antes que
/// "niño" siempre en el mismo orden).
int compareAlphabetical(String a, String b) {
  final byKey = alphabeticalKey(a).compareTo(alphabeticalKey(b));
  return byKey != 0 ? byKey : a.toLowerCase().compareTo(b.toLowerCase());
}

/// Clave de orden: minúsculas, sin diacríticos y sin los signos del
/// principio ("¿", "¡", comillas, paréntesis).
String alphabeticalKey(String s) {
  final lower = s.toLowerCase().replaceFirst(_leadingSymbols, '');
  final buffer = StringBuffer();
  for (final ch in lower.split('')) {
    buffer.write(_fold[ch] ?? ch);
  }
  return buffer.toString();
}

final _leadingSymbols = RegExp(r'^[^\p{L}\p{N}]+', unicode: true);

const Map<String, String> _fold = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
  'ý': 'y', 'ÿ': 'y',
  'ñ': 'n', 'ç': 'c', 'š': 's', 'ž': 'z', 'č': 'c', 'ł': 'l',
};
