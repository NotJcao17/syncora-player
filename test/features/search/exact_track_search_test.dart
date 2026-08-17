import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';
import 'package:syncora_player/features/search/exact_track_search.dart';
import 'package:syncora_player/features/search/search_ranking.dart';

/// Tests de ExactTrackSearch (Fase D, D3) — funciones puras directas, más un
/// caso con fixture grabada para el escenario que motivó D3: un tema que el
/// buscador normal (Fase A) nunca trae en el pool de 100 resultados con texto
/// plano, pero que la sintaxis avanzada sí resuelve (ver
/// docs/plan_buscador_importacion_matcher.md, hallazgo A7 y sección Fase D).
///
/// No se testea `cascadeSearch` en sí (hace llamadas de red vía `DeezerApi`) —
/// mismo criterio ya documentado para B2/B3 en test/data/import_export_test.dart:
/// fuera del alcance de tests reproducibles, verificado manualmente/contra la
/// API real durante el diseño.
List<DeezerTrack> _parseRawDeezerResponse(String fileName) {
  final file = File('test/fixtures/exact_search/$fileName.json');
  final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final raw = decoded['data'] as List;
  return raw
      .where((t) => ((t as Map)['duration'] as int? ?? 0) > 60 && t['type'] != 'podcast')
      .map((t) => DeezerTrack.fromJson(Map<String, dynamic>.from(t as Map)))
      .toList();
}

void main() {
  group('ExactTrackSearch — funciones puras', () {
    test('queryTitle quita sufijos "(feat. X)"', () {
      expect(ExactTrackSearch.queryTitle('Conqueror (feat. Someone)'), equals('Conqueror'));
      expect(ExactTrackSearch.queryTitle('Uptown Funk - feat. Bruno Mars'), equals('Uptown Funk'));
      expect(ExactTrackSearch.queryTitle('Solo Título'), equals('Solo Título'));
    });

    test('queryTitle quita "featuring"/"ft."/"with" sin distinguir mayúsculas', () {
      expect(ExactTrackSearch.queryTitle('Song featuring Someone'), equals('Song'));
      expect(ExactTrackSearch.queryTitle('Song ft. Someone'), equals('Song'));
      expect(ExactTrackSearch.queryTitle('Song With Someone'), equals('Song'));
    });

    test('primaryArtist toma el primero antes de ";"', () {
      expect(ExactTrackSearch.primaryArtist('Gente De Zona;Marc Anthony'), equals('Gente De Zona'));
      expect(ExactTrackSearch.primaryArtist('Solo Artista'), equals('Solo Artista'));
      expect(ExactTrackSearch.primaryArtist(''), equals(''));
    });

    test('forQuery quita comillas literales para no romper la sintaxis avanzada', () {
      expect(ExactTrackSearch.forQuery('Artista "Apodo"'), equals('Artista Apodo'));
    });

    group('bestByDuration', () {
      final tracks = [
        DeezerTrack(id: 1, title: 'A', artistName: 'X', artistId: 1, albumTitle: '', albumId: 0, coverUrl: '', durationSec: 200),
        DeezerTrack(id: 2, title: 'B', artistName: 'X', artistId: 1, albumTitle: '', albumId: 0, coverUrl: '', durationSec: 210),
        DeezerTrack(id: 3, title: 'C', artistName: 'X', artistId: 1, albumTitle: '', albumId: 0, coverUrl: '', durationSec: 400),
      ];

      test('sin duración esperada, confía en el primero (ya rankeado)', () {
        expect(ExactTrackSearch.bestByDuration(tracks, null, toleranceSec: 5)?.id, equals(1));
      });

      test('elige el candidato más cercano dentro de la tolerancia', () {
        final best = ExactTrackSearch.bestByDuration(tracks, 208000, toleranceSec: 20);
        expect(best?.id, equals(2)); // 210s es más cercano a 208s que 200s
      });

      test('descarta si nada cae dentro de la tolerancia (evita Live/Remix)', () {
        final best = ExactTrackSearch.bestByDuration(tracks, 208000, toleranceSec: 1);
        expect(best, isNull);
      });

      test('lista vacía devuelve null', () {
        expect(ExactTrackSearch.bestByDuration(const [], 200000, toleranceSec: 20), isNull);
      });
    });
  });

  group('ExactTrackSearch — caso real D3 (fixture grabada)', () {
    test(
      'artist:"Adele" track:"Someone Like You" SÍ trae a la Adele real, a diferencia '
      'del buscador normal (Fase A, A7): confirma el hueco que D3 resuelve',
      () {
        final tracks = _parseRawDeezerResponse('adele_someone_like_you_advanced');
        // Pool pequeño y lleno de decoys ("Hello Adele Tribute", "Made famous
        // by Adele", karaokes, remixes) — justo el tipo de ruido que Fase A
        // nunca llega a ver porque, con texto plano, la Adele real ni
        // aparece en 100 resultados.
        expect(tracks, isNotEmpty);
        expect(tracks.any((t) => t.artistName == 'Adele'), isTrue);

        final ranked = SearchRanking.rankTracks(tracks, 'Adele Someone Like You');
        final top = ranked.first;
        expect(top.id, equals(1174603092));
        expect(top.artistName, equals('Adele'));
      },
    );
  });
}
