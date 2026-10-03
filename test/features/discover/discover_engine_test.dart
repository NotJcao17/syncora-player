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
    test('con historial: radio de un artista parecido, nunca de los que ya escucha', () async {
      final api = _FakeApi()
        ..related[100] = [const DeezerArtist(id: 200, name: 'Parecido', pictureUrl: '', nbFan: 0)]
        ..radios[200] = [_t(1, artist: 200), _t(2, artist: 201), _t(3, artist: 100), _t(4, artist: 202)];
      final source = DiscoverSource(api: api, seedArtistIds: [100], listenedTrackIds: {4}, random: Random(1));

      final batch = await source.nextBatch(exclude: const {}, minSize: 1);
      expect(batch.map((t) => t.id).toSet(), {1, 2},
          reason: '3 es del artista semilla (ya lo conoce) y 4 ya se escuchó');
      expect(api.chartCalls, 0);
    });

    test('no repite el mismo relacionado: el segundo lote cae al top global', () async {
      final api = _FakeApi()
        ..related[100] = [const DeezerArtist(id: 200, name: 'P', pictureUrl: '', nbFan: 0)]
        ..radios[200] = [_t(1, artist: 200)]
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
