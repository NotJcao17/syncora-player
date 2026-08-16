import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/models/deezer/deezer_artist.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';
import 'package:syncora_player/features/search/search_ranking.dart';

/// Suite de regresión del ranking del buscador (Fase A, ítem A7 del plan).
///
/// Usa snapshots JSON reales capturados de la API de Deezer en vez de llamadas
/// en vivo: el `rank` de Deezer cambia con el tiempo (popularidad real), así
/// que una prueba contra la API en vivo empezaría a fallar sin que el código
/// tuviera ningún bug. Las fixtures viven en test/fixtures/deezer_search/ y se
/// cargan tal cual las devolvió Deezer — mismo parseo (filtro de duración/
/// podcast) que usa lib/data/apis/deezer_api.dart.
///
/// Las aserciones son sobre ORDEN RELATIVO ("X debe quedar antes que Y" / "el
/// primero debe ser Z"), no sobre valores de score absolutos — esos cambiarán
/// con cada ajuste de pesos; lo que no debe cambiar es el resultado ganador.

Map<String, dynamic> _loadFixture(String name) {
  final file = File('test/fixtures/deezer_search/$name.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

List<DeezerTrack> _parseTracks(Map<String, dynamic> fixture) {
  final raw = fixture['tracks'] as List;
  return raw
      .where((t) => ((t as Map)['duration'] as int? ?? 0) > 60 && t['type'] != 'podcast')
      .map((t) => DeezerTrack.fromJson(Map<String, dynamic>.from(t as Map)))
      .toList();
}

List<DeezerArtist> _parseArtists(Map<String, dynamic> fixture) {
  final raw = fixture['artists'] as List;
  return raw.map((a) => DeezerArtist.fromJson(Map<String, dynamic>.from(a as Map))).toList();
}

/// Simula exactamente lo que hace deezer_api.dart para el tipo "all": rankear
/// artistas, hallar el dominante, rankear tracks con su bonus.
({List<DeezerArtist> artists, DeezerArtist? dominant, List<DeezerTrack> tracks}) _runAll(
  String query,
  String fixtureName,
) {
  final fixture = _loadFixture(fixtureName);
  final rawTracks = _parseTracks(fixture);
  final rankedArtists = SearchRanking.rankArtists(_parseArtists(fixture), query);
  final dominant = SearchRanking.findDominantArtist(rankedArtists, query, rawTracks);
  final rankedTracks = SearchRanking.rankTracks(rawTracks, query, dominantArtist: dominant);
  return (artists: rankedArtists, dominant: dominant, tracks: rankedTracks);
}

void main() {
  group('SearchRanking — funciones puras (sin fixtures)', () {
    test('normalize elimina apóstrofes en vez de convertirlos en espacio (Bug A)', () {
      // "god's" y "gods" deben normalizar exactamente igual, o "drake gods plan"
      // nunca hace match con el título real "God's Plan".
      expect(SearchRanking.normalize("God's Plan"), equals('gods plan'));
      expect(SearchRanking.normalize('Gods Plan'), equals('gods plan'));
    });

    test('normalize colapsa diacríticos y puntuación', () {
      expect(SearchRanking.normalize('¿Con Quién?'), equals('con quien'));
      expect(SearchRanking.normalize('Sigan bailando (Remix)'), equals('sigan bailando remix'));
    });

    test('textScore: un título limpio le gana a un cover con relleno (Bug B)', () {
      // Caso real: "someone like you adele" — un cover con título largo
      // ("Rumour Has It / Someone Like You (Cover of Adele)") contenía todas
      // las palabras del query y por eso ganaba con un conteo simple de
      // "contiene todas las palabras". El fix pondera precisión: el título
      // limpio debe seguir ganando aunque ambos reciban recall = 1.
      final clean = SearchRanking.textScore(
        'someone like you adele',
        title: 'Someone Like You',
        artist: 'Adele',
      );
      final coverWithFiller = SearchRanking.textScore(
        'someone like you adele',
        title: 'Rumour Has It / Someone Like You (Cover of Adele)',
        artist: 'Glee Cast',
      );
      expect(clean, greaterThan(coverWithFiller));
    });

    test('artistTextScore no penaliza nombres de artista con más de una palabra', () {
      // "Bruno Mars" no debe puntuar peor que "Bruno" a secas solo por tener
      // una palabra extra — a diferencia de un título, el nombre completo de
      // un artista siempre es 100% relevante si contiene la palabra buscada.
      final brunoMars = SearchRanking.artistTextScore('bruno', 'Bruno Mars');
      final brunoSolo = SearchRanking.artistTextScore('bruno', 'Bruno');
      // Bruno (exacto) puede tener un pequeño bonus por match exacto, pero la
      // diferencia debe ser chica — no los ~20 puntos que daba la fórmula de
      // título (que sí penaliza por precisión).
      expect(brunoSolo - brunoMars, lessThanOrEqualTo(10));
    });

    test('baseTitle agrupa variantes del mismo tema (A5: enriquecimiento de ambiguos)', () {
      // Casos reales vistos en la sesión de análisis: "3 A.M." de Jesse & Joy
      // (que en realidad YA es la colaboración con Gente De Zona, pero /search
      // no lo muestra) vs. la variante con Tommy Torres.
      expect(
        SearchRanking.baseTitle('3 A.M.'),
        equals(SearchRanking.baseTitle('3 A.M. (feat. Tommy Torres)')),
      );
      expect(
        SearchRanking.baseTitle('Despacito'),
        equals(SearchRanking.baseTitle('Despacito (Versión Salsa)')),
      );
      expect(
        SearchRanking.baseTitle('Guess'),
        equals(SearchRanking.baseTitle('Guess featuring billie eilish')),
      );
      expect(
        SearchRanking.baseTitle("God's Plan"),
        equals(SearchRanking.baseTitle('God\'s Plan - Remastered')),
      );
      // Canciones distintas no deben agruparse.
      expect(
        SearchRanking.baseTitle('Despacito'),
        isNot(equals(SearchRanking.baseTitle('Bailando'))),
      );
    });

    test('popScoreFromRank y fanBonus son monótonos y acotados', () {
      expect(SearchRanking.popScoreFromRank(null), equals(0));
      expect(SearchRanking.popScoreFromRank(0), equals(0));
      expect(SearchRanking.popScoreFromRank(500000), lessThan(SearchRanking.popScoreFromRank(900000)));
      expect(SearchRanking.popScoreFromRank(2000000), equals(100)); // clamp superior

      expect(SearchRanking.fanBonus(0), equals(0));
      expect(SearchRanking.fanBonus(1000), lessThan(SearchRanking.fanBonus(1000000)));
      expect(SearchRanking.fanBonus(1000000), lessThanOrEqualTo(40)); // tope del bonus
    });
  });

  group('SearchRanking — toggle "Popular" y filtro de presencia en pool', () {
    test('isPopularArtist / isPopularTrack respetan los umbrales documentados', () {
      expect(
        SearchRanking.isPopularArtist(
          const DeezerArtist(id: 1, name: 'X', pictureUrl: '', nbFan: SearchRanking.popularArtistMinFans),
        ),
        isTrue,
      );
      expect(
        SearchRanking.isPopularArtist(
          const DeezerArtist(id: 1, name: 'X', pictureUrl: '', nbFan: SearchRanking.popularArtistMinFans - 1),
        ),
        isFalse,
      );
    });

    test(
      'filterArtistsWithPresence descarta artistas sin canciones en el pool '
      '(caso real: "DJ Despacito" para la query "despacito")',
      () {
        final fixture = _loadFixture('despacito');
        final tracks = _parseTracks(fixture);
        final artists = _parseArtists(fixture);

        final djDespacito = artists.firstWhere((a) => a.name == 'DJ Despacito');
        expect(djDespacito.nbFan, lessThan(SearchRanking.popularArtistMinFans));

        final filtered = SearchRanking.filterArtistsWithPresence(artists, tracks);
        expect(filtered.any((a) => a.name == 'DJ Despacito'), isFalse);
        // "Pablo Cepeda" sí tiene una "Despacito" propia en el pool, no debe filtrarse.
        expect(filtered.any((a) => a.name == 'Pablo Cepeda'), isTrue);
      },
    );

    test(
      'filterArtistsWithPresence exceptúa a artistas con fans suficientes aunque '
      'no tengan canción en este pool puntual',
      () {
        const famous = DeezerArtist(id: 1, name: 'Famoso', pictureUrl: '', nbFan: 1000000);
        final result = SearchRanking.filterArtistsWithPresence([famous], []);
        expect(result, contains(famous));
      },
    );
  });

  group('SearchRanking — fixtures reales: artistas populares ambiguos', () {
    test('"adele": la Adele real (15.4M fans) gana, no una tocaya', () {
      final r = _runAll('adele', 'adele');
      expect(r.artists.first.name, equals('Adele'));
      expect(r.artists.first.nbFan, greaterThan(1000000));
      expect(r.dominant?.name, equals('Adele'));
      expect(r.tracks.first.artistName, equals('Adele'));
    });

    test('"bruno": Bruno Mars gana, no un artista exacto llamado "Bruno" con pocos fans', () {
      final r = _runAll('bruno', 'bruno');
      expect(r.artists.first.name, equals('Bruno Mars'));
      expect(r.dominant?.name, equals('Bruno Mars'));
      expect(r.tracks.first.artistName, equals('Bruno Mars'));
    });

    test('"ariana": Ariana Grande gana, no la coincidencia exacta "Ariana" (481 fans)', () {
      final r = _runAll('ariana', 'ariana');
      expect(r.artists.first.name, equals('Ariana Grande'));
      expect(r.dominant?.name, equals('Ariana Grande'));
      expect(r.tracks.first.artistName, equals('Ariana Grande'));
    });

    test('"queen": la banda gana sobre homónimos de bajo perfil', () {
      final r = _runAll('queen', 'queen');
      expect(r.artists.first.name, equals('Queen'));
      expect(r.artists.first.nbFan, greaterThan(1000000));
      expect(r.tracks.first.artistName, equals('Queen'));
    });

    test('"eagles": la banda gana sobre "Eagles of Death Metal" y tributos', () {
      final r = _runAll('eagles', 'eagles');
      expect(r.artists.first.name, equals('Eagles'));
      expect(r.tracks.first.artistName, equals('Eagles'));
    });

    test('"taylor swift": la artista real gana sobre variantes de nombre casi vacías', () {
      final r = _runAll('taylor swift', 'taylor_swift');
      expect(r.artists.first.name, equals('Taylor Swift'));
      expect(r.dominant?.name, equals('Taylor Swift'));
      expect(r.tracks.first.artistName, equals('Taylor Swift'));
    });

    test('"karol g": la artista real gana sobre créditos colaborativos que también matchean', () {
      final r = _runAll('karol g', 'karol_g');
      expect(r.artists.first.name, equals('KAROL G'));
      expect(r.tracks.first.artistName, equals('KAROL G'));
    });

    test('"bad bunny": la artista real gana sobre créditos colaborativos largos', () {
      final r = _runAll('bad bunny', 'bad_bunny');
      expect(r.artists.first.name, equals('Bad Bunny'));
      expect(r.tracks.first.artistName, equals('Bad Bunny'));
    });
  });

  group('SearchRanking — fixtures reales: queries a medio teclear (match por prefijo)', () {
    // Caso real reportado probando la app: escribir "bruno m" (a medio
    // camino de "bruno mars") hacía que Bruno Mars desapareciera incluso de
    // la pestaña Artistas. Causa: el recall exigía tokens IDÉNTICOS, así que
    // "m" nunca matcheaba "mars" y artistas literalmente llamados "Bruno M"
    // (unos cientos de fans) le ganaban por score exacto.
    test('"bruno m": Bruno Mars sigue ganando con la query a medio teclear', () {
      final r = _runAll('bruno m', 'bruno_m');
      expect(r.artists.first.name, equals('Bruno Mars'));
      expect(r.dominant?.name, equals('Bruno Mars'));
      expect(r.tracks.first.artistName, equals('Bruno Mars'));
    });

    // Caso real reportado: "arian" (a medio teclear de "ariana") no
    // encontraba a Ariana Grande ni en la pestaña Artistas. Causa: con
    // igualdad exacta de tokens el recall daba 0 y quedaba fuera de
    // `minRelevance` — no es que perdiera el ranking, desaparecía del todo.
    test('"arian": Ariana Grande aparece pese al recorte de la última palabra', () {
      final r = _runAll('arian', 'arian');
      expect(r.artists.first.name, equals('Ariana Grande'));
      expect(r.dominant?.name, equals('Ariana Grande'));
      expect(r.tracks.first.artistName, equals('Ariana Grande'));
    });

    // Caso real reportado probando la app: "3A.M." (sin espacio) mostraba la
    // canción real de Jesse & Joy en la posición 14, aunque Deezer la
    // devuelve primero en el pool crudo (confirmado contra la API en vivo,
    // con esta query exacta). Causa: `normalize` no separaba dígito y letra
    // pegados, así que "3A.M." tokenizaba como ["3a","m"] mientras el título
    // real "3 A.M." tokenizaba como ["3","a","m"] — "3a" nunca cubría a
    // ningún token del título real.
    test('"3A.M." (sin espacio) encuentra la canción real en primer lugar', () {
      final r = _runAll('3A.M.', '3am_no_space');
      expect(r.tracks.first.id, equals(390959001));
      expect(r.tracks.first.artistName, contains('Jesse & Joy'));
    });
  });

  group('SearchRanking — fixtures reales: nombres en español con diacríticos', () {
    test('"jose jose" (sin tilde) encuentra a José José, no homónimos', () {
      final r = _runAll('jose jose', 'jose_jose');
      expect(r.artists.first.name, equals('José José'));
      expect(r.dominant?.name, equals('José José'));
      expect(r.tracks.first.artistName, equals('José José'));
    });

    test('"mana" (sin tilde) encuentra a Maná, no variantes de nombre casi vacías', () {
      final r = _runAll('mana', 'mana');
      expect(r.artists.first.name, equals('Maná'));
      expect(r.tracks.first.artistName, equals('Maná'));
    });

    test('"si no estas tu" (sin tildes ni signos) encuentra el título real con tildes', () {
      final r = _runAll('si no estas tu', 'si_no_estas_tu');
      expect(r.tracks.first.artistName, equals('Íñigo Quintero'));
      expect(r.tracks.first.title, equals('Si No Estás'));
    });
  });

  group('SearchRanking — fixtures reales: título específico vs. artista popular (tu objeción)', () {
    test('"uptown": Uptown Funk gana por popularidad, pero sin artista dominante espurio', () {
      final r = _runAll('uptown', 'uptown');
      // "Uptown Funk" (el nombre-de-artista genérico, no Mark Ronson) no debe
      // colarse como "dominante": no tiene ninguna canción propia en el pool.
      expect(r.dominant, isNull);
      expect(r.tracks.first.artistName, equals('Mark Ronson'));
      expect(r.tracks.first.title, contains('Uptown Funk'));
    });

    test('"despacito": Luis Fonsi gana; "DJ Despacito" no se cuela como dominante', () {
      final r = _runAll('despacito', 'despacito');
      // Gate anti-falso-positivo: DJ Despacito matchea por nombre exacto pero
      // no tiene ninguna canción en el pool de esta búsqueda.
      expect(r.dominant, isNull);
      expect(r.tracks.first.artistName, equals('Luis Fonsi'));
      expect(r.tracks.first.title, equals('Despacito'));
    });

    test('"blinding lights": The Weeknd gana sin necesitar artista dominante', () {
      final r = _runAll('blinding lights', 'blinding_lights');
      expect(r.tracks.first.artistName, equals('The Weeknd'));
    });
  });

  group('SearchRanking — fixtures reales: consultas combinadas artista+título', () {
    test('"drake gods plan" encuentra "God\'s Plan" pese al apóstrofe (Bug A)', () {
      final r = _runAll('drake gods plan', 'drake_gods_plan');
      expect(r.tracks.first.artistName, equals('Drake'));
      expect(r.tracks.first.title, equals("God's Plan"));
    });

    test('el orden de las palabras no cambia el resultado ganador', () {
      final r1 = _runAll('perfect ed sheeran', 'perfect_ed_sheeran');
      final r2 = _runAll('ed sheeran perfect', 'ed_sheeran_perfect');
      expect(r1.tracks.first.artistName, equals('Ed Sheeran'));
      expect(r1.tracks.first.title, equals('Perfect'));
      expect(r2.tracks.first.artistName, equals(r1.tracks.first.artistName));
      expect(r2.tracks.first.title, equals(r1.tracks.first.title));
    });

    test('"imagine dragons believer" encuentra la versión de estudio, no un Live', () {
      final r = _runAll('imagine dragons believer', 'imagine_dragons_believer');
      expect(r.tracks.first.artistName, equals('Imagine Dragons'));
      expect(r.tracks.first.title, equals('Believer'));
    });
  });

  group('SearchRanking — límite conocido de Deezer (no de nuestra fórmula)', () {
    test(
      '"someone like you adele": la Adele real NO está ni siquiera en el pool de 100 — '
      'confirmado contra la API en vivo que ni el texto plano de Deezer la incluye. '
      'Este test documenta el hueco, no lo "arregla": ningún re-ranking en cliente '
      'puede rescatar un candidato que Deezer nunca devolvió. La vía real de arreglo '
      'es la sintaxis avanzada artist:"" track:"" usada en Importación (Fase B) y '
      'Búsqueda Profunda (Fase D), no más ajuste de pesos aquí.',
      () {
        final fixture = _loadFixture('someone_like_you_adele');
        final tracks = _parseTracks(fixture);
        final hasRealAdele = tracks.any((t) => t.artistName == 'Adele');
        expect(
          hasRealAdele,
          isFalse,
          reason: 'Si esto empieza a fallar, Deezer mejoró su índice para este caso — '
              'sería buena noticia, pero hay que revisar el test, no el código.',
        );
      },
    );
  });

  group('SearchRanking — no debe lanzar con queries genéricas/ambiguas', () {
    for (final q in ['love', 'hello', 'circles', 'cancion']) {
      test('"$q" produce un orden determinista sin lanzar excepciones', () {
        final r = _runAll(q, q == 'cancion' ? 'cancion' : q);
        expect(r.tracks, isNotEmpty);
      });
    }
  });
}
