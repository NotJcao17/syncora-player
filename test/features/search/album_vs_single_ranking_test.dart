import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/models/deezer/deezer_album.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';
import 'package:syncora_player/features/search/search_ranking.dart';

/// Ronda 3, F1 y F3.
///
/// F3 no ajusta puntuaciones: **intercambia posiciones** dentro del grupo de
/// "la misma grabacion del mismo artista". La primera version si restaba
/// puntos y eso tuvo un efecto colateral real (ver el test "no altera el orden
/// de terceros"), asi que estos tests fijan tanto lo que SI intercambia como
/// todo lo que debe dejar intacto.

DeezerTrack _track({
  required int id,
  required String title,
  required String album,
  int artistId = 7,
  int rank = 500000,
}) {
  return DeezerTrack(
    id: id,
    title: title,
    artistName: 'Artista',
    artistId: artistId,
    albumTitle: album,
    albumId: id * 10,
    coverUrl: '',
    durationSec: 200,
    rank: rank,
  );
}

void main() {
  group('F1 - record_type en DeezerAlbum', () {
    DeezerAlbum parse(String? recordType) => DeezerAlbum.fromJson({
          'id': 1,
          'title': 'X',
          'artist': {'id': 7, 'name': 'Artista'},
          'cover_medium': '',
          'release_date': '2024-01-01',
          'record_type': ?recordType,
        });

    test('separa sencillos y EP de albumes', () {
      expect(parse('single').isSingleOrEp, isTrue);
      expect(parse('ep').isSingleOrEp, isTrue);
      expect(parse('album').isSingleOrEp, isFalse);
      expect(parse('compilation').isSingleOrEp, isFalse);
    });

    test('normaliza mayusculas', () {
      expect(parse('SINGLE').isSingleOrEp, isTrue);
    });

    test('sin el campo, se trata como album', () {
      // `/album/{id}` embebido en otras respuestas no trae record_type; el
      // caso mayoritario es que sea un album, y esconderlo seria peor que
      // clasificarlo de mas.
      expect(parse(null).isSingleOrEp, isFalse);
      expect(parse(null).isFullAlbum, isTrue);
    });
  });

  group('F3 - deteccion de sencillo', () {
    test('album titulado igual que la pista', () {
      expect(
        SearchRanking.looksLikeSingleRelease(_track(id: 1, title: 'Espresso', album: 'Espresso')),
        isTrue,
      );
    });

    test('album con sufijo de tipo de lanzamiento', () {
      expect(
        SearchRanking.looksLikeSingleRelease(
            _track(id: 1, title: 'Espresso', album: 'Espresso - Single')),
        isTrue,
      );
      expect(
        SearchRanking.looksLikeSingleRelease(
            _track(id: 1, title: 'Von dutch', album: 'Von dutch EP')),
        isTrue,
      );
    });

    test('album de verdad no cuenta como sencillo', () {
      expect(
        SearchRanking.looksLikeSingleRelease(
            _track(id: 1, title: 'Espresso', album: 'Short n\' Sweet')),
        isFalse,
      );
    });

    test('sin titulo de album no se asume nada', () {
      expect(
        SearchRanking.looksLikeSingleRelease(_track(id: 1, title: 'Espresso', album: '')),
        isFalse,
      );
    });
  });

  group('F3 - preferencia de la version de album', () {
    test('con la misma popularidad gana la version de album', () {
      final single = _track(id: 1, title: 'Espresso', album: 'Espresso');
      final album = _track(id: 2, title: 'Espresso', album: "Short n' Sweet");

      final ranked = SearchRanking.rankTracks([single, album], 'espresso');

      expect(ranked.first.id, 2);
    });

    test('NO se promueve una version de album marginal', () {
      // Guard contra el caso de §6.8: Deezer devuelve entradas de
      // recopilaciones que desde /search son indistinguibles de un album
      // real. Si la "version de album" apenas tiene popularidad, no se
      // asciende.
      final single = _track(id: 1, title: 'Espresso', album: 'Espresso', rank: 900000);
      final recopilacion = _track(id: 2, title: 'Espresso', album: 'Nu Pop 2024', rank: 20000);

      final ranked = SearchRanking.rankTracks([single, recopilacion], 'espresso');

      expect(ranked.first.id, 1);
    });

    test('sin alternativa de album, el sencillo se queda donde esta', () {
      final soloSingle = _track(id: 1, title: 'Espresso', album: 'Espresso', rank: 500000);
      final otra = _track(id: 2, title: 'Espresso Martini', album: 'Cocteles', rank: 400000);

      final ranked = SearchRanking.rankTracks([soloSingle, otra], 'espresso');
      expect(ranked.first.id, 1);
    });

    test('la alternativa tiene que ser del MISMO artista', () {
      final single = _track(id: 1, title: 'Espresso', album: 'Espresso', artistId: 7);
      final coverDeOtro =
          _track(id: 2, title: 'Espresso', album: 'Versiones', artistId: 99, rank: 500000);

      final ranked = SearchRanking.rankTracks([single, coverDeOtro], 'espresso');

      expect(ranked.first.id, 1);
    });

    test('un feat. NO es la misma grabacion: no se intercambia', () {
      // Regresion real que descubrio la suite con la fixture "3A.M.":
      // agrupar por `baseTitle` fusionaba "3 A.M." de Jesse & Joy con
      // "3 A.M. (feat. Tommy Torres)", que es otra grabacion distinta.
      final single = _track(id: 1, title: '3 A.M.', album: '3 A.M.', rank: 540454);
      final conFeat = _track(
        id: 2,
        title: '3 A.M. (feat. Tommy Torres)',
        album: 'Un Besito Mas',
        rank: 212109,
      );

      final ranked = SearchRanking.rankTracks([single, conFeat], '3 a m');

      expect(ranked.first.id, 1);
    });

    test('duraciones muy distintas no son la misma grabacion', () {
      final single = _track(id: 1, title: 'Espresso', album: 'Espresso');
      final remixLargo = DeezerTrack(
        id: 2,
        title: 'Espresso',
        artistName: 'Artista',
        artistId: 7,
        albumTitle: 'Remixes',
        albumId: 20,
        coverUrl: '',
        durationSec: 420,
        rank: 500000,
      );

      final ranked = SearchRanking.rankTracks([single, remixLargo], 'espresso');

      expect(ranked.first.id, 1);
    });

    test('es un intercambio posicional: no altera el orden de terceros', () {
      // El primer intento de F3 restaba puntos, y eso hizo caer al sencillo
      // correcto por debajo de una cancion de OTRO artista que no tenia nada
      // que ver con el desempate. Un intercambio dentro del grupo no puede
      // hacer eso, por construccion.
      final single = _track(id: 1, title: 'Espresso', album: 'Espresso', rank: 540000);
      final album = _track(id: 2, title: 'Espresso', album: "Short n' Sweet", rank: 530000);
      final ajena = _track(
        id: 3,
        title: 'Espresso',
        album: 'Otro Disco',
        artistId: 42,
        rank: 535000,
      );

      final sinF3 = SearchRanking.rankTracks([ajena], 'espresso');
      final conF3 = SearchRanking.rankTracks([single, album, ajena], 'espresso');

      expect(sinF3.first.id, 3);
      // La ajena sigue en medio: el intercambio solo movio a 1 y 2 entre si.
      expect(conF3.map((t) => t.id).toList(), [2, 3, 1]);
    });
  });
}
