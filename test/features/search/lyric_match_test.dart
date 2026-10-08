import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/search/ai_lyric_search/lyric_match.dart';

void main() {
  const lyrics = '''[00:12.10]Ojalá que llueva café en el campo
[00:16.40]Que caiga un aguacero de yuca y té
Del cielo una jarina de queso blanco''';

  test('fragmento literal, sin acentos ni puntuación', () {
    expect(LyricMatch.score('que caiga un aguacero de yuca y te', lyrics), 1);
    expect(LyricMatch.isConfirmed('Ojala que llueva cafe!!', lyrics), isTrue);
  });

  test('una palabra mal recordada no lo descarta', () {
    expect(LyricMatch.isConfirmed('que caiga un chaparron de yuca y te', lyrics), isTrue);
  });

  test('un fragmento de otra canción no se confirma', () {
    expect(LyricMatch.isConfirmed('I threw a wish in the well', lyrics), isFalse);
  });

  test('contracciones en inglés', () {
    expect(LyricMatch.isConfirmed("don't ask me, I'll never tell", "I threw a wish in the well\nDon't ask me, I'll never tell"), isTrue);
  });

  test('letra vacía', () {
    expect(LyricMatch.score('hola', ''), 0);
  });
}
