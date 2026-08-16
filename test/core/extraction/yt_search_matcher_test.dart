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

  // C9 — Fase C: cobertura de regresión para el matcher reescrito. Ver
  // docs/plan_buscador_importacion_matcher.md, sección "Fase C", ítem C9,
  // para el checklist completo que agrupa estos tests.

  group('C1: requisito de título rechaza canción equivocada', () {
    test('mismo artista, misma duración exacta, canción distinta -> rechazado', () {
      final candidates = [
        {
          'videoId': 'wrongSong01',
          'title': 'Taylor Swift - Blank Space (Official Video)',
          'author': 'TaylorSwiftVEVO',
          'durationSec': 200,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Taylor Swift',
        title: 'Style',
        durationSec: 200,
      );

      // Duración idéntica y artista confirmado (VEVO) no deben rescatar un
      // candidato cuyo título no comparte ningún token con "Style".
      expect(best, isNull);
    });
  });

  group('C2/C9: el rechazo por término indeseado no depende del tamaño de la lista', () {
    test('karaoke rechazado con N=1', () {
      final candidates = [
        {
          'videoId': 'karaokeOnly1',
          'title': 'Silver Lining (Karaoke Version)',
          'author': 'Karaoke Channel',
          'durationSec': 210,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Test Artist Three',
        title: 'Silver Lining',
        durationSec: 210,
      );

      expect(best, isNull);
    });

    test('el mismo karaoke rechazado con N=5, incluso siendo el primero de la lista', () {
      final candidates = [
        {
          'videoId': 'karaokeFirst',
          'title': 'Silver Lining (Karaoke Version)',
          'author': 'Karaoke Channel',
          'durationSec': 210,
        },
        {'videoId': 'unrelated0001', 'title': 'Some Other Track', 'author': 'Channel A', 'durationSec': 210},
        {'videoId': 'unrelated0002', 'title': 'Totally Different Song', 'author': 'Channel B', 'durationSec': 210},
        {'videoId': 'unrelated0003', 'title': 'Nothing Related Here', 'author': 'Channel C', 'durationSec': 210},
        {'videoId': 'unrelated0004', 'title': 'Another Unrelated Video', 'author': 'Channel D', 'durationSec': 210},
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Test Artist Three',
        title: 'Silver Lining',
        durationSec: 210,
      );
      final top = YtSearchMatcher.pickTopCandidates(
        candidates,
        artist: 'Test Artist Three',
        title: 'Silver Lining',
        durationSec: 210,
      );

      // El bonus de posición (índice 0) no debe rescatar al karaoke: sigue
      // descalificado de plano, y el resto no pasa el filtro de título.
      expect(best, isNull);
      expect(top, isEmpty);
    });
  });

  group('C3: confirmación de artista', () {
    test('canal VEVO concatenado sin espacios confirma al artista', () {
      final candidates = [
        {
          'videoId': 'vevoConcat01',
          'title': 'Taylor Swift - Shake It Off (Official Music Video)',
          'author': 'TaylorSwiftVEVO',
          'durationSec': null,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Taylor Swift',
        title: 'Shake It Off',
        durationSec: null,
      );

      // Sin duración conocida en ningún lado, la aceptación depende
      // enteramente de que "taylorswiftvevo" confirme a "Taylor Swift".
      expect(best, isNotNull);
      expect(best!.artistConfirmed, isTrue);
    });

    test('colaboración "A, B" confirma con solo uno de los dos nombres', () {
      final candidates = [
        {
          'videoId': 'collabMatch1',
          'title': 'Bruno Mars - Uptown Funk (Official Video)',
          'author': 'Bruno Mars',
          'durationSec': 270,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Mark Ronson, Bruno Mars',
        title: 'Uptown Funk',
        durationSec: 270,
      );

      expect(best, isNotNull);
      expect(best!.artistConfirmed, isTrue);
    });

    test('canal "- Topic" suma un bonus de calidad de canal', () {
      final withTopic = YtSearchMatcher.pickBest(
        [
          {
            'videoId': 'topicChannel',
            'title': 'Anthem',
            'author': 'Bruno Mars - Topic',
            'durationSec': 200,
          },
        ],
        artist: 'Bruno Mars',
        title: 'Anthem',
        durationSec: 200,
      );

      final withoutTopic = YtSearchMatcher.pickBest(
        [
          {
            'videoId': 'plainChannel',
            'title': 'Anthem',
            'author': 'Bruno Mars',
            'durationSec': 200,
          },
        ],
        artist: 'Bruno Mars',
        title: 'Anthem',
        durationSec: 200,
      );

      expect(withTopic, isNotNull);
      expect(withoutTopic, isNotNull);
      // Mismo escenario salvo el sufijo "- Topic": la diferencia de score
      // debe ser exactamente el bonus de canal (+30).
      expect(withTopic!.score - withoutTopic!.score, equals(30));
    });
  });

  group('C4: términos indeseados — exención simétrica y guardas de substring', () {
    test('título esperado con "Live" no descalifica a un candidato con "Live"', () {
      final candidates = [
        {
          'videoId': 'legitLive001',
          'title': 'Artist - Song (Live)',
          'author': 'Artist',
          'durationSec': 200,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Artist',
        title: 'Song (Live)',
        durationSec: 200,
      );

      expect(best, isNotNull);
    });

    test('título esperado con "Remix" no descalifica a un candidato con "Remix"', () {
      final candidates = [
        {
          'videoId': 'legitRemix01',
          'title': 'Artist - Song (Remix) [Official Audio]',
          'author': 'Artist',
          'durationSec': 200,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Artist',
        title: 'Song (Remix)',
        durationSec: 200,
      );

      expect(best, isNotNull);
    });

    test('"Undercover Martyn" no dispara "cover" (límite de palabra, no substring)', () {
      final candidates = [
        {
          'videoId': 'undercoverM1',
          'title': 'Two Door Cinema Club - Undercover Martyn',
          'author': 'Two Door Cinema Club',
          'durationSec': 203,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Two Door Cinema Club',
        title: 'Undercover Martyn',
        durationSec: 203,
      );

      expect(best, isNotNull);
    });

    test('"Coverdale" no dispara "cover" (límite de palabra, no substring)', () {
      final candidates = [
        {
          'videoId': 'coverdale001',
          'title': 'Whitesnake - Here I Go Again (Coverdale Version) [Official Audio]',
          'author': 'Whitesnake',
          'durationSec': 333,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Whitesnake',
        title: 'Here I Go Again',
        durationSec: 333,
      );

      expect(best, isNotNull);
    });

    test('"Chain Reaction" como título real no dispara "reaction" (exención simétrica)', () {
      final candidates = [
        {
          'videoId': 'chainReact01',
          'title': 'Diana Ross - Chain Reaction (Official Video)',
          'author': 'Diana Ross',
          'durationSec': 227,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Diana Ross',
        title: 'Chain Reaction',
        durationSec: 227,
      );

      expect(best, isNotNull);
    });

    test('"Trailer Trash" como título real no dispara "trailer" (exención simétrica)', () {
      final candidates = [
        {
          'videoId': 'trailerTrsh1',
          'title': 'Cracker - Trailer Trash (Official Audio)',
          'author': 'Cracker',
          'durationSec': 195,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Cracker',
        title: 'Trailer Trash',
        durationSec: 195,
      );

      expect(best, isNotNull);
    });
  });

  group('C7: robustez de durationSec (null, 0 y double)', () {
    // Score esperado cuando el bloque de duración se salta por completo
    // (porque durationSec esperado es null o 0): solo cuenta título (100%
    // de solape de un único token -> 60) + artistConfirmed (+50) + bonus de
    // posición en índice 0 (+10) = 120. Si el viejo bug (-50 a todos cuando
    // durationSec era 0) siguiera presente, el score sería 70.
    const expectedScoreNoDurationBlock = 120;

    test('durationSec esperado null no aplica penalización -50 ni cuenta como "en rango"', () {
      final candidates = [
        {
          'videoId': 'durNullCase1',
          'title': 'Wonderland',
          'author': 'Artist',
          'durationSec': 999, // muy distinta; no debe importar, el bloque se salta
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Artist',
        title: 'Wonderland',
        durationSec: null,
      );

      expect(best, isNotNull);
      expect(best!.score, equals(expectedScoreNoDurationBlock));
    });

    test('durationSec esperado 0 (fallback de Deezer) se comporta igual que null', () {
      final candidates = [
        {
          'videoId': 'durZeroCase1',
          'title': 'Wonderland',
          'author': 'Artist',
          'durationSec': 999,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Artist',
        title: 'Wonderland',
        durationSec: 0,
      );

      expect(best, isNotNull);
      expect(best!.score, equals(expectedScoreNoDurationBlock));
    });

    test('durationSec del candidato en 0 tampoco cuenta como "en rango" ni aplica penalización', () {
      final candidates = [
        {
          'videoId': 'durZeroCand1',
          'title': 'Wonderland',
          'author': 'Artist',
          'durationSec': 0,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Artist',
        title: 'Wonderland',
        durationSec: 200,
      );

      expect(best, isNotNull);
      expect(best!.score, equals(expectedScoreNoDurationBlock));
    });

    test('durationSec null/0 sin artista confirmado no pasa el umbral de aceptación', () {
      final candidates = [
        {
          'videoId': 'durNullNoArt',
          'title': 'Wonderland',
          'author': 'Completely Unrelated Uploader',
          'durationSec': null,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Artist',
        title: 'Wonderland',
        durationSec: null,
      );

      expect(best, isNull);
    });

    test('durationSec como double (JSON) no lanza y se trata igual que int', () {
      final candidates = [
        {
          'videoId': 'durAsDouble1',
          'title': 'Echoes',
          'author': 'Test Artist Two',
          'durationSec': 210.0,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Test Artist Two',
        title: 'Echoes',
        durationSec: 210,
      );

      expect(best, isNotNull);
      expect(best!.durationSec, equals(210));
    });
  });

  group('norm(): scripts no latinos se preservan', () {
    test('coreano, japonés y cirílico no se vacían al normalizar', () {
      expect(YtSearchMatcher.norm('봄날!'), equals('봄날'));
      expect(YtSearchMatcher.norm('ラブストーリーは突然に'), isNotEmpty);
      expect(YtSearchMatcher.norm('Любовь Это!'), equals('любовь это'));
    });

    test('título coreano hace round-trip completo contra un candidato equivalente', () {
      final candidates = [
        {
          'videoId': 'koreanTitle1',
          'title': '방탄소년단 봄날 (Official MV)',
          'author': '방탄소년단',
          'durationSec': 100,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: '방탄소년단',
        title: '봄날',
        durationSec: 100,
      );

      expect(best, isNotNull);
      expect(best!.artistConfirmed, isTrue);
    });
  });

  group('Frontera del umbral: solapamiento de título (50%)', () {
    test('exactamente 50% de solape pasa el filtro de título', () {
      final candidates = [
        {
          'videoId': 'overlap50pct',
          'title': 'TestArtist One Two Official Audio',
          'author': 'TestArtist',
          'durationSec': 200,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'TestArtist',
        title: 'One Two Three Four',
        durationSec: 200,
      );

      expect(best, isNotNull);
    });

    test('justo por debajo del 50% de solape (25%) es rechazado', () {
      final candidates = [
        {
          'videoId': 'overlap25pct',
          'title': 'TestArtist One Official Audio',
          'author': 'TestArtist',
          'durationSec': 200,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'TestArtist',
        title: 'One Two Three Four',
        durationSec: 200,
      );

      expect(best, isNull);
    });
  });

  group('Frontera del umbral: tolerancia de duración (20s)', () {
    test('diff de 20s cuenta como "en rango" y es aceptado sin artista confirmado', () {
      final candidates = [
        {
          'videoId': 'durDiff20sec',
          'title': 'Wonderland2',
          'author': 'Completely Different Uploader',
          'durationSec': 220,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Unrelated Artist Name',
        title: 'Wonderland2',
        durationSec: 200,
      );

      expect(best, isNotNull);
    });

    test('diff de 21s ya no cuenta como "en rango" y sin artista confirmado es rechazado', () {
      final candidates = [
        {
          'videoId': 'durDiff21sec',
          'title': 'Wonderland2',
          'author': 'Completely Different Uploader',
          'durationSec': 221,
        },
      ];

      final best = YtSearchMatcher.pickBest(
        candidates,
        artist: 'Unrelated Artist Name',
        title: 'Wonderland2',
        durationSec: 200,
      );

      expect(best, isNull);
    });

    test('diff > 30s aplica la penalización -50 solo cuando ambas duraciones son reales', () {
      // Con artistConfirmed=true el candidato igual se acepta (evidencia
      // positiva vía artista), pero el score debe reflejar la penalización.
      final penalized = YtSearchMatcher.pickBest(
        [
          {
            'videoId': 'penaltyDiff40',
            'title': 'Skylight',
            'author': 'Contrast Artist',
            'durationSec': 240, // diff = 40 > 30
          },
        ],
        artist: 'Contrast Artist',
        title: 'Skylight',
        durationSec: 200,
      );

      final noBonusNoPenalty = YtSearchMatcher.pickBest(
        [
          {
            'videoId': 'noPenaltyD25',
            'title': 'Skylight',
            'author': 'Contrast Artist',
            'durationSec': 225, // diff = 25, entre 20 y 30: ni bonus ni penalización
          },
        ],
        artist: 'Contrast Artist',
        title: 'Skylight',
        durationSec: 200,
      );

      expect(penalized, isNotNull);
      expect(noBonusNoPenalty, isNotNull);
      // title(60) + artistConfirmed(50) + posición(10) = 120 de base en ambos;
      // el de diff=40 resta 50 adicionales por la penalización.
      expect(noBonusNoPenalty!.score, equals(120));
      expect(penalized!.score, equals(70));
    });
  });

  group('C12: pase relajado como último recurso (caso real de tema de nicho)', () {
    // Caso reportado en vivo: "Sofia Giusti - Antes De Que Salga El Sol".
    // El upload existe pero el canal no lleva el nombre del artista y la
    // duración no viene en los resultados de búsqueda, así que no hay
    // corroboración posible: el pase estricto lo rechazaba y la pista
    // terminaba en `notFound` -> auto-skip, sin forma de reproducirla.
    final nicheCandidates = <Map<String, dynamic>>[
      {
        'videoId': 'nicheUpload1',
        'title': 'Antes De Que Salga El Sol',
        'author': 'Canal Random De Musica',
        'durationSec': null,
      },
    ];

    test('estricto rechaza: sin duración ni artista confirmado no hay corroboración', () {
      final best = YtSearchMatcher.pickBest(
        nicheCandidates,
        artist: 'Sofia Giusti',
        title: 'Antes De Que Salga El Sol',
        durationSec: 166,
      );
      expect(best, isNull);
    });

    test('relajado lo acepta: el título coincide al 100%', () {
      final best = YtSearchMatcher.pickBest(
        nicheCandidates,
        artist: 'Sofia Giusti',
        title: 'Antes De Que Salga El Sol',
        durationSec: 166,
        relaxed: true,
      );
      expect(best, isNotNull);
      expect(best!.videoId, equals('nicheUpload1'));
      expect(best.artistConfirmed, isFalse);
    });

    test('relajado NO acepta karaokes/covers: relajar no es rendirse', () {
      final best = YtSearchMatcher.pickBest(
        [
          {
            'videoId': 'karaokeNiche',
            'title': 'Antes De Que Salga El Sol (Karaoke)',
            'author': 'Canal De Karaoke',
            'durationSec': null,
          },
        ],
        artist: 'Sofia Giusti',
        title: 'Antes De Que Salga El Sol',
        durationSec: 166,
        relaxed: true,
      );
      expect(best, isNull);
    });

    test('relajado exige MÁS título que el estricto (70% vs 50%)', () {
      // 3 de 6 tokens = 50%: pasa el estricto (con corroboración de
      // duración), pero no llega al 70% que exige el relajado.
      final candidates = <Map<String, dynamic>>[
        {
          'videoId': 'halfTitle01',
          'title': 'Antes De Que',
          'author': 'Otro Canal',
          'durationSec': 166,
        },
      ];

      expect(
        YtSearchMatcher.pickBest(
          candidates,
          artist: 'Sofia Giusti',
          title: 'Antes De Que Salga El Sol',
          durationSec: 166,
        ),
        isNotNull,
        reason: 'estricto: 50% de título + duración exacta corrobora',
      );
      expect(
        YtSearchMatcher.pickBest(
          candidates,
          artist: 'Sofia Giusti',
          title: 'Antes De Que Salga El Sol',
          durationSec: 166,
          relaxed: true,
        ),
        isNull,
        reason: 'relajado: sin corroboración se exige 70% de título',
      );
    });

    test('el pase relajado sigue prefiriendo al candidato con artista confirmado', () {
      final ranked = YtSearchMatcher.pickTopCandidates(
        [
          {
            'videoId': 'randomChan1',
            'title': 'Antes De Que Salga El Sol',
            'author': 'Canal Random',
            'durationSec': null,
          },
          {
            'videoId': 'realArtist1',
            'title': 'Antes De Que Salga El Sol',
            'author': 'Sofia Giusti',
            'durationSec': null,
          },
        ],
        artist: 'Sofia Giusti',
        title: 'Antes De Que Salga El Sol',
        durationSec: 166,
        relaxed: true,
      );

      expect(ranked.first.videoId, equals('realArtist1'));
      expect(ranked.first.artistConfirmed, isTrue);
    });
  });

  group('pickTopCandidates: múltiples candidatos rankeados', () {
    test('devuelve varios candidatos ordenados por score y acotados a topN', () {
      final candidates = [
        {
          // Score alto: duración exacta, término de calidad en título,
          // canal VEVO y artista confirmado.
          'videoId': 'topPickA',
          'title': 'Anthem (Official Audio)',
          'author': 'Test Band VEVO',
          'durationSec': 200,
        },
        {
          // Score medio: duración con diff=10, artista confirmado, sin
          // términos de calidad ni canal especial.
          'videoId': 'topPickB',
          'title': 'Anthem',
          'author': 'Test Band',
          'durationSec': 210,
        },
        {
          // Pasa el umbral solo por duración en rango (diff=5), sin
          // artista confirmado ni términos de calidad -> score más bajo.
          'videoId': 'topPickD',
          'title': 'Anthem',
          'author': 'Someone Else',
          'durationSec': 205,
        },
        {
          // No pasa el umbral: ni duración conocida en rango ni artista
          // confirmado -> debe quedar excluido del todo.
          'videoId': 'topPickC',
          'title': 'Anthem Lyrics',
          'author': 'Random Channel',
          'durationSec': null,
        },
      ];

      final top2 = YtSearchMatcher.pickTopCandidates(
        candidates,
        artist: 'Test Band',
        title: 'Anthem',
        durationSec: 200,
        topN: 2,
      );

      expect(top2.length, equals(2));
      expect(top2[0].videoId, equals('topPickA'));
      expect(top2[1].videoId, equals('topPickB'));
      expect(top2[0].score, greaterThan(top2[1].score));

      // Con topN más grande que el número de candidatos que superan el
      // umbral, la lista se acota al número real de aprobados (3), no se
      // rellena ni incluye al que no pasó el filtro (topPickC).
      final top5 = YtSearchMatcher.pickTopCandidates(
        candidates,
        artist: 'Test Band',
        title: 'Anthem',
        durationSec: 200,
        topN: 5,
      );

      expect(top5.length, equals(3));
      expect(top5.map((c) => c.videoId), isNot(contains('topPickC')));
    });
  });
}
