import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/models/deezer/deezer_playlist.dart';
import 'package:syncora_player/features/home/home_providers.dart';

DeezerPlaylist top(String title) => DeezerPlaylist(
      id: title.hashCode.abs(),
      title: title,
      pictureUrl: '',
      nbTracks: 100,
      userName: 'Deezer Charts',
    );

void main() {
  group('sortCountryTopsForHome', () {
    test('México va primero: es el mercado para el que se desarrolla', () {
      final sorted = sortCountryTopsForHome([
        top('Top Japan'),
        top('Top France'),
        top('Top Mexico'),
        top('Top Worldwide'),
      ]);

      expect(sorted.first.title, 'Top Mexico');
      expect(sorted[1].title, 'Top Worldwide');
    });

    test('los destacados respetan el orden de la lista, no el alfabético', () {
      final sorted = sortCountryTopsForHome([
        top('Top Argentina'),
        top('Top Usa'),
        top('Top Mexico'),
      ]);

      expect(sorted.map((p) => p.title), ['Top Mexico', 'Top Usa', 'Top Argentina']);
    });

    test('lo no destacado queda después, ordenado alfabéticamente', () {
      final sorted = sortCountryTopsForHome([
        top('Top Zambia'),
        top('Top Albania'),
        top('Top Mexico'),
      ]);

      expect(sorted.map((p) => p.title), ['Top Mexico', 'Top Albania', 'Top Zambia']);
    });

    test('no pierde ni duplica entradas', () {
      final input = [top('Top Mexico'), top('Top Peru'), top('Top Worldwide')];
      expect(sortCountryTopsForHome(input).length, input.length);
    });

    test('no muta la lista recibida', () {
      final input = [top('Top Peru'), top('Top Mexico')];
      sortCountryTopsForHome(input);
      expect(input.first.title, 'Top Peru');
    });
  });
}
