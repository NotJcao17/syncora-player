import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/apis/deezer_api.dart';
import 'package:syncora_player/data/models/deezer/deezer_artist.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';
import 'package:syncora_player/features/discover/discover_engine.dart';

DeezerTrack _t(int id, {int artist = 1, String? preview = 'https://cdnt-preview.dzcdn.net/x.mp3'}) => DeezerTrack(
      id: id,
      title: 'T$id',
      artistName: 'A$artist',
      artistId: artist,
      albumTitle: 'Al',
      albumId: 1,
      coverUrl: '',
      durationSec: 200,
      previewUrl: preview,
    );

class _FakeApi extends DeezerApi {
  final Map<int, List<DeezerArtist>> related = {};
  final Map<int, List<DeezerTrack>> radios = {};
  final Map<int, List<DeezerTrack>> tops = {};

  @override
  Future<List<DeezerTrack>> getArtistTopTracks(int id, {int limit = 10}) async => tops[id] ?? const [];
  List<DeezerTrack> chart = [];
  int chartCalls = 0;

  @override
  Future<List<DeezerArtist>> getArtistRelated(int artistId) async => related[artistId] ?? const [];

  @override
  Future<List<DeezerTrack>> getArtistRadio(int artistId) async => radios[artistId] ?? const [];

  @override
  Future<List<DeezerTrack>> getTopCharts() async {
    chartCalls++;
    return chart;
  }
}

void main() {
  group('DiscoverEngine.pickFresh', () {
    test('quita lo ya escuchado, lo que no tiene preview y a los artistas que ya conoce', () {
      final picked = DiscoverEngine.pickFresh(
        [_t(1), _t(2, preview: null), _t(3), _t(4, artist: 9), _t(1)],
        exclude: {3},
        excludeArtists: {9},
        random: Random(1),
      );
      expect(picked.map((t) => t.id), [1]);
    });

    test('como mucho N por artista para que el feed no sea monotemático', () {
      final picked = DiscoverEngine.pickFresh(
        [for (var i = 1; i <= 6; i++) _t(i, artist: 5), _t(7, artist: 6)],
        exclude: const {},
        maxPerArtist: 2,
        random: Random(1),
      );
      expect(picked.where((t) => t.artistId == 5).length, 2);
      expect(picked.any((t) => t.id == 7), isTrue);
    });
  });

  group('DiscoverSource', () {
    test('mezcla mitad y mitad: populares de parecidos (un salto) y su radio (dos saltos)', () async {
      final api = _FakeApi()
        ..related[100] = [
          const DeezerArtist(id: 200, name: 'P1', pictureUrl: '', nbFan: 0),
          const DeezerArtist(id: 201, name: 'P2', pictureUrl: '', nbFan: 0),
        ]
        ..tops[200] = [_t(10, artist: 200), _t(11, artist: 200), _t(12, artist: 200)]
        ..tops[201] = [_t(20, artist: 201), _t(21, artist: 201)]
        ..radios[200] = [for (var i = 30; i < 40; i++) _t(i, artist: i)]
        ..radios[201] = [for (var i = 30; i < 40; i++) _t(i, artist: i)];
      final source = DiscoverSource(api: api, seedArtistIds: [100], listenedTrackIds: const {}, random: Random(3));

      final batch = await source.nextBatch(exclude: const {}, minSize: 1);
      final familiar = batch.where((t) => t.artistId == 200 || t.artistId == 201).toList();
      final discovery = batch.where((t) => t.artistId >= 30 && t.artistId < 40).toList();
      expect(familiar.length, 4, reason: '2 más populares de cada parecido');
      expect(familiar.map((t) => t.id), isNot(contains(12)), reason: 'solo las 2 más populares');
      expect(discovery.length, familiar.length, reason: 'mitad y mitad');
      for (var i = 0; i < batch.length; i += 2) {
        expect(familiar.contains(batch[i]), isTrue, reason: 'intercaladas: reconocible, descubrimiento, ...');
      }
    });

    test('sin canciones reconocibles disponibles va solo con descubrimiento', () async {
      final api = _FakeApi()
        ..related[100] = [const DeezerArtist(id: 200, name: 'Parecido', pictureUrl: '', nbFan: 0)]
        ..radios[200] = [_t(1, artist: 200), _t(2, artist: 201), _t(3, artist: 100), _t(4, artist: 202)];
      final source = DiscoverSource(api: api, seedArtistIds: [100], listenedTrackIds: {4}, random: Random(1));

      final batch = await source.nextBatch(exclude: const {}, minSize: 1);
      expect(batch.map((t) => t.id).toSet(), {2},
          reason: '1 es del propio parecido (iría en la parte reconocible), 3 del artista semilla '
              '(ya lo conoce) y 4 ya se escuchó');
      expect(api.chartCalls, 0);
    });

    test('no repite el mismo relacionado: el segundo lote cae al top global', () async {
      final api = _FakeApi()
        ..related[100] = [const DeezerArtist(id: 200, name: 'P', pictureUrl: '', nbFan: 0)]
        ..radios[200] = [_t(1, artist: 250)]
        ..chart = [_t(50, artist: 300)];
      final source = DiscoverSource(api: api, seedArtistIds: [100], listenedTrackIds: const {}, random: Random(1));

      expect((await source.nextBatch(exclude: const {}, minSize: 1)).map((t) => t.id), [1]);
      expect((await source.nextBatch(exclude: {1}, minSize: 1)).map((t) => t.id), [50]);
      expect(await source.nextBatch(exclude: {1, 50}, minSize: 1), isEmpty, reason: 'el top global se usa una vez');
    });

    test('sin historial usa el top global', () async {
      final api = _FakeApi()..chart = [_t(1), _t(2, artist: 2)];
      final source = DiscoverSource(api: api, seedArtistIds: const [], listenedTrackIds: const {}, random: Random(1));
      expect(source.hasHistory, isFalse);
      expect((await source.nextBatch(exclude: {2})).map((t) => t.id), [1]);
    });
  });
}
