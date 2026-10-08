import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/search/ai_lyric_search/ai_lyric_search_sheet.dart';

void main() {
  test('filas de YouTube Music a filas del matcher, sin repetidas ni incompletas', () {
    final rows = rawTracksFromMusicRows([
      {'videoId': 'a', 'title': 'Periódico de Ayer', 'author': 'Héctor Lavoe', 'durationSec': 330},
      {'videoId': 'b', 'title': 'Periódico de Ayer', 'author': 'Héctor Lavoe', 'durationSec': 331},
      {'videoId': 'c', 'title': 'Sin artista', 'author': ''},
      {'videoId': 'd', 'title': 'Soñando Despierto', 'author': 'Willie Colón', 'durationSec': null},
    ]);
    expect(rows.map((r) => r.title), ['Periódico de Ayer', 'Soñando Despierto']);
    expect(rows.first.artist, 'Héctor Lavoe');
    expect(rows.first.durationMs, 330000);
    expect(rows.last.durationMs, isNull);
  });
}
