import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';
import 'package:syncora_player/features/search/collaboration_search.dart';

/// Tests de CollaborationSearch (Fase D, D1) contra fixtures reales
/// capturadas de la API de Deezer: top tracks (con `limit=100`, ver
/// [getArtistTopTracksExpanded]) de Charli xcx y de Billie Eilish, más una
/// búsqueda de texto plano "Charli xcx Billie Eilish" — el caso real
/// documentado en el plan ("Guess" con Billie Eilish, ninguno de los dos
/// artistas por separado la posiciona bien).
///
/// No se testea `CollaborationSearch.search` en sí (hace llamadas de red vía
/// `DeezerApi`) — mismo criterio que en el resto del proyecto: se testea la
/// lógica pura de filtrado/matching de forma offline y reproducible.
List<DeezerTrack> _parseRawDeezerResponse(String fileName) {
  final file = File('test/fixtures/collaboration_search/$fileName.json');
  final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final raw = decoded['data'] as List;
  return raw
      .where((t) => ((t as Map)['duration'] as int? ?? 0) > 60 && t['type'] != 'podcast')
      .map((t) => DeezerTrack.fromJson(Map<String, dynamic>.from(t as Map)))
      .toList();
}

void main() {
  group('CollaborationSearch.trackHasArtist', () {
    test('matchea por id de contributor (señal fuerte, top tracks)', () {
      final track = DeezerTrack(
        id: 1,
        title: 'Guess featuring billie eilish',
        artistName: 'Charli xcx',
        artistId: 1462230,
        albumTitle: '',
        albumId: 0,
        coverUrl: '',
        durationSec: 143,
        contributorsList: const [],
      );
      // Sin contributors reales (como llegan de /search sin enriquecer), el
      // fallback por título debe rescatar a Billie Eilish.
      expect(CollaborationSearch.trackHasArtist(track, artistName: 'Billie Eilish'), isTrue);
      expect(CollaborationSearch.trackHasArtist(track, artistName: 'Charli xcx'), isTrue);
      expect(CollaborationSearch.trackHasArtist(track, artistName: 'Dua Lipa'), isFalse);
    });
  });

  group('CollaborationSearch — caso real D1 (fixtures grabadas)', () {
    test('el pool combinado (top de Charli + top de Billie + texto plano) contiene "Guess"', () {
      final charliTop = _parseRawDeezerResponse('charli_xcx_top');
      final billieTop = _parseRawDeezerResponse('billie_eilish_top');
      final plain = _parseRawDeezerResponse('charli_billie_plain');

      final seenIds = <int>{};
      final pool = <DeezerTrack>[
        for (final t in [...plain, ...charliTop, ...billieTop])
          if (seenIds.add(t.id)) t,
      ];

      final matches = CollaborationSearch.filterCollaborations(
        pool,
        artist1Name: 'Charli xcx',
        artist1Id: 1462230,
        artist2Name: 'Billie Eilish',
        artist2Id: 9635624,
      );

      expect(matches, isNotEmpty);
      expect(matches.any((t) => t.title.toLowerCase().contains('guess')), isTrue);
    });

    test('excluye canciones solistas de cada artista (no ambos presentes)', () {
      final charliTop = _parseRawDeezerResponse('charli_xcx_top');
      final matches = CollaborationSearch.filterCollaborations(
        charliTop,
        artist1Name: 'Charli xcx',
        artist1Id: 1462230,
        artist2Name: 'Billie Eilish',
        artist2Id: 9635624,
      );
      // Todo lo que matcheó tiene que mencionar a Billie Eilish de alguna
      // forma — nada de temas solistas de Charli se cuela.
      for (final t in matches) {
        expect(CollaborationSearch.trackHasArtist(t, artistName: 'Billie Eilish', artistId: 9635624), isTrue);
      }
      expect(matches.length, lessThan(charliTop.length));
    });
  });
}
