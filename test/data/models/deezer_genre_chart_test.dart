import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/models/deezer/deezer_genre.dart';

Map<String, dynamic> track(int id, int artistId, String artistName) => {
      'id': id,
      'title': 'Pista $id',
      'duration': 200,
      'artist': {'id': artistId, 'name': artistName},
      'album': {'id': 1, 'title': 'Álbum', 'cover_medium': ''},
    };

void main() {
  group('DeezerGenreChart', () {
    // Verificado contra la API en vivo: `/chart/{genre_id}` devuelve la MISMA
    // lista global de artistas para cualquier género, así que la sección
    // "Artistas de Rock" mostraba a los mismos que "Artistas de Pop". Los
    // artistas se derivan de las pistas, que sí son del género.
    test('ignora la lista de artistas de Deezer y la deriva de las pistas', () {
      final chart = DeezerGenreChart.fromJson({
        'tracks': {
          'data': [track(1, 10, 'Artista A'), track(2, 20, 'Artista B')],
        },
        'artists': {
          'data': [
            {'id': 999, 'name': 'Artista Global Que No Es Del Género'},
          ],
        },
      });

      expect(chart.artists.map((a) => a.name), ['Artista A', 'Artista B']);
    });

    test('no repite artistas y respeta el orden de aparición', () {
      final chart = DeezerGenreChart.fromJson({
        'tracks': {
          'data': [
            track(1, 10, 'Artista A'),
            track(2, 20, 'Artista B'),
            track(3, 10, 'Artista A'),
          ],
        },
      });

      expect(chart.artists.map((a) => a.id), [10, 20]);
    });

    test('la foto usa el redirector de Deezer, que no cuesta una petición extra', () {
      final chart = DeezerGenreChart.fromJson({
        'tracks': {
          'data': [track(1, 42, 'Artista A')],
        },
      });

      expect(chart.artists.single.pictureUrl, contains('/artist/42/image'));
    });

    test('descarta pistas sin artista válido en vez de inventar una entrada', () {
      final chart = DeezerGenreChart.fromJson({
        'tracks': {
          'data': [
            {'id': 1, 'title': 'Sin artista', 'duration': 200},
            track(2, 20, 'Artista B'),
          ],
        },
      });

      expect(chart.artists.map((a) => a.id), [20]);
    });

    test('filtra podcasts e interludios cortos, como el resto de la app', () {
      final chart = DeezerGenreChart.fromJson({
        'tracks': {
          'data': [
            {...track(1, 10, 'Artista A'), 'duration': 30},
            {...track(2, 20, 'Artista B'), 'type': 'podcast'},
            track(3, 30, 'Artista C'),
          ],
        },
      });

      expect(chart.tracks.map((t) => t.id), [3]);
      expect(chart.artists.map((a) => a.id), [30]);
    });

    test('sobrevive al viaje de ida y vuelta por el caché', () {
      final original = DeezerGenreChart.fromJson({
        'tracks': {
          'data': [track(1, 10, 'Artista A'), track(2, 20, 'Artista B')],
        },
      });

      final restored = DeezerGenreChart.fromJson(original.toJson());

      expect(restored.tracks.length, original.tracks.length);
      expect(restored.artists.map((a) => a.id), original.artists.map((a) => a.id));
    });
  });
}
