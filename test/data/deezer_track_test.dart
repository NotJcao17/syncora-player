import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';

/// Caso real reportado probando la app: "Uptown Funk (feat. Bruno Mars)"
/// mostraba "Mark Ronson, Bruno Mars, Bruno Mars" — confirmado contra la API
/// en vivo que `/track/{id}` lista al mismo colaborador dos veces con roles
/// distintos ("Main" y "Featured", mismo id). No es un bug de diseño nuestro,
/// es un dato real de Deezer; el parser no deduplicaba por id.
void main() {
  group('DeezerTrack.fromJson — deduplica contributors repetidos por rol', () {
    test('mismo id con rol "Main" y "Featured" no se duplica', () {
      final track = DeezerTrack.fromJson({
        'id': 92734438,
        'title': 'Uptown Funk (feat. Bruno Mars)',
        'duration': 270,
        'artist': {'id': 13204, 'name': 'Mark Ronson'},
        'album': {'id': 1, 'title': 'Uptown Special'},
        'contributors': [
          {'id': 13204, 'name': 'Mark Ronson', 'role': 'Main'},
          {'id': 429675, 'name': 'Bruno Mars', 'role': 'Main'},
          {'id': 429675, 'name': 'Bruno Mars', 'role': 'Featured'},
        ],
      });

      expect(track.contributorsList, hasLength(2));
      expect(track.contributorsList.map((c) => c.name), equals(['Mark Ronson', 'Bruno Mars']));
      expect(track.artistName, equals('Mark Ronson, Bruno Mars'));
    });

    test('colaboradores sin id (0) distintos no se fusionan entre sí', () {
      final track = DeezerTrack.fromJson({
        'id': 1,
        'title': 'Track',
        'duration': 200,
        'artist': {'id': 1, 'name': 'A'},
        'album': {'id': 1, 'title': 'Album'},
        'contributors': [
          {'id': 0, 'name': 'A'},
          {'id': 0, 'name': 'B'},
        ],
      });

      expect(track.contributorsList.map((c) => c.name), equals(['A', 'B']));
    });
  });
}
