import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/extraction/yt_search_matcher.dart';

void main() {
  group('YtSearchMatcher', () {
    test('norm normaliza minúsculas, acentos y signos', () {
      expect(YtSearchMatcher.norm('Canción - Artista (Official Video)!'), equals('cancion artista official video'));
      expect(YtSearchMatcher.norm('Éxito & Más'), equals('exito mas'));
    });

    test('pickBest selecciona candidato con duración cercana y artista coincidente', () {
      final candidates = [
        {
          'videoId': 'vid11111111',
          'title': 'Random Track Cover',
          'author': 'Cover Channel',
          'durationSec': 210,
        },
        {
          'videoId': 'vid22222222',
          'title': 'Daft Punk - One More Time (Official Audio)',
          'author': 'Daft Punk VEVO',
          'durationSec': 320,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Daft Punk',
        title: 'One More Time',
        durationSec: 320,
      );

      expect(best, isNotNull);
      expect(best!.videoId, equals('vid22222222'));
      expect(best.score, greaterThan(100));
    });

    test('pickBest penaliza covers y karaokes', () {
      final candidates = [
        {
          'videoId': 'coverId1234',
          'title': 'Artist - Song (Karaoke Cover)',
          'author': 'Karaoke King',
          'durationSec': 200,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Artist',
        title: 'Song',
        durationSec: 200,
      );

      // Score será negativo por ser karaoke + cover (-160)
      expect(best, isNull);
    });

    test('pickBest retorna null si la lista de candidatos está vacía', () {
      final best = YtSearchMatcher.pickBest(
        [],
        artist: 'Artist',
        title: 'Song',
      );
      expect(best, isNull);
    });
  });
}
