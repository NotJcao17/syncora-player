import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/models/deezer/deezer_album.dart';
import 'package:syncora_player/features/search/other_versions_search.dart';

/// Tests de OtherVersionsSearch (Fase D, D2). El caso real usado en las
/// fixtures es el documentado en el plan: "Guess" de Charli xcx, cuya
/// versión solista (id 2837358742) existe en el álbum "Brat and it's the
/// same but there's three more songs so it's not" pero no aparece bajo
/// ninguna query de `/search` — solo se encuentra listando los tracks del
/// álbum directamente. Fixtures capturadas de la API real:
/// test/fixtures/other_versions_search/.
DeezerAlbum _makeAlbum(int id, String releaseDate) => DeezerAlbum.fromJson({
      'id': id,
      'title': 'Album $id',
      'artist': {'id': 1, 'name': 'Artist'},
      'release_date': releaseDate,
    });

List<DeezerAlbum> _loadArtistAlbumsFixture() {
  final file = File('test/fixtures/other_versions_search/charli_xcx_albums.json');
  final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final raw = decoded['data'] as List;
  return raw.map((a) => DeezerAlbum.fromJson(Map<String, dynamic>.from(a as Map))).toList();
}

DeezerAlbum _loadFullAlbumFixture(String fileName) {
  final file = File('test/fixtures/other_versions_search/$fileName.json');
  final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return DeezerAlbum.fromJson(decoded);
}

void main() {
  group('OtherVersionsSearch.nearestAlbums', () {
    test('sin fecha de referencia, respeta el orden de entrada (ya viene más reciente primero)', () {
      final albums = [
        _makeAlbum(1, '2024-01-01'),
        _makeAlbum(2, '2020-01-01'),
        _makeAlbum(3, '2018-01-01'),
      ];
      final result = OtherVersionsSearch.nearestAlbums(albums, null, maxAlbums: 2);
      expect(result.map((a) => a.id), equals([1, 2]));
    });

    test('con fecha de referencia, ordena por cercanía absoluta (no por más reciente)', () {
      final reference = DateTime(2024, 6, 10);
      final albums = [
        _makeAlbum(1, '2013-04-12'), // muy lejos
        _makeAlbum(2, '2024-08-01'), // 52 días después
        _makeAlbum(3, '2024-06-07'), // 3 días antes — el más cercano
        _makeAlbum(4, '2024-06-10'), // exacto
      ];
      final result = OtherVersionsSearch.nearestAlbums(albums, reference, maxAlbums: 3);
      expect(result.map((a) => a.id), equals([4, 3, 2]));
    });

    test('acota a maxAlbums incluso con muchos álbumes cercanos', () {
      final reference = DateTime(2024, 1, 1);
      final albums = List.generate(30, (i) => _makeAlbum(i, '2024-01-0${(i % 9) + 1}'));
      final result = OtherVersionsSearch.nearestAlbums(albums, reference, maxAlbums: 10);
      expect(result.length, equals(10));
    });

    test('álbumes sin release_date quedan al final, no rompen el orden', () {
      final reference = DateTime(2024, 6, 10);
      final albums = [
        _makeAlbum(1, ''),
        _makeAlbum(2, '2024-06-07'),
      ];
      final result = OtherVersionsSearch.nearestAlbums(albums, reference, maxAlbums: 5);
      expect(result.map((a) => a.id), equals([2]));
    });
  });

  group('OtherVersionsSearch.filterMatchingTitle', () {
    test('agrupa por título base: "Guess" y "Guess featuring billie eilish" son la misma canción', () {
      final albumWithTracks = DeezerAlbum.fromJson({
        'id': 1,
        'title': 'Test',
        'artist': {'id': 1, 'name': 'Artist'},
        'release_date': '2024-06-10',
        'tracks': {
          'data': [
            {'id': 10, 'title': 'Guess', 'duration': 142, 'artist': {'id': 1, 'name': 'Charli xcx'}},
            {'id': 11, 'title': 'Von dutch', 'duration': 160, 'artist': {'id': 1, 'name': 'Charli xcx'}},
          ],
        },
      });
      final matches = OtherVersionsSearch.filterMatchingTitle([albumWithTracks], 'Guess featuring billie eilish');
      expect(matches.map((t) => t.id), equals([10]));
    });

    test('deduplica por id entre álbumes distintos', () {
      final a1 = DeezerAlbum.fromJson({
        'id': 1,
        'title': 'A1',
        'artist': {'id': 1, 'name': 'Artist'},
        'release_date': '2024-01-01',
        'tracks': {
          'data': [
            {'id': 10, 'title': 'Guess', 'duration': 142, 'artist': {'id': 1, 'name': 'Artist'}},
          ],
        },
      });
      final a2 = DeezerAlbum.fromJson({
        'id': 2,
        'title': 'A2',
        'artist': {'id': 1, 'name': 'Artist'},
        'release_date': '2024-02-01',
        'tracks': {
          'data': [
            {'id': 10, 'title': 'Guess', 'duration': 142, 'artist': {'id': 1, 'name': 'Artist'}},
          ],
        },
      });
      final matches = OtherVersionsSearch.filterMatchingTitle([a1, a2], 'Guess');
      expect(matches.length, equals(1));
    });
  });

  group('OtherVersionsSearch — caso real D2 (fixtures grabadas)', () {
    test(
      'con la fecha de la colaboración como referencia, el álbum con la versión solista de '
      '"Guess" queda entre los más cercanos (3 días de diferencia)',
      () {
        final albums = _loadArtistAlbumsFixture();
        // "Guess featuring billie eilish" (single, 2024-08-01) es la
        // colaboración que el usuario ya tiene y desde la que dispara
        // "buscar otras versiones" (entrada 1 de D2, track_tile.dart).
        const collaborationAlbumId = 623577791;
        final refAlbum = albums.firstWhere((a) => a.id == collaborationAlbumId);
        final referenceDate = DateTime.parse(refAlbum.releaseDate);

        final candidates = OtherVersionsSearch.nearestAlbums(albums, referenceDate, maxAlbums: 15);
        // El álbum real que contiene la versión solista.
        expect(candidates.any((a) => a.id == 598319362), isTrue);
      },
    );

    test('el álbum candidato, una vez cargado completo, SÍ trae la versión solista de "Guess"', () {
      final fullAlbum = _loadFullAlbumFixture('brat_three_more_songs_album');
      final matches = OtherVersionsSearch.filterMatchingTitle([fullAlbum], 'Guess featuring billie eilish');
      expect(matches, isNotEmpty);
      expect(matches.first.id, equals(2837358742));
      expect(matches.first.title, equals('Guess'));
    });
  });
}
