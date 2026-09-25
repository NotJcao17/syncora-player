import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/apis/deezer_api.dart';
import 'package:syncora_player/data/apis/deezer_provider.dart';
import 'package:syncora_player/data/models/deezer/deezer_search_result.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';
import 'package:syncora_player/features/search/search_provider.dart';

class _TwoPhaseApi extends DeezerApi {
  final enrichGate = Completer<void>();
  bool? lastEnrichFlag;

  static const _raw = DeezerTrack(id: 1, title: 'Cruda', artistName: 'A', artistId: 1, albumId: 1, albumTitle: 'X', coverUrl: '', durationSec: 200);
  static const _rich = DeezerTrack(id: 1, title: 'Enriquecida', artistName: 'A', artistId: 1, albumId: 1, albumTitle: 'X', coverUrl: '', durationSec: 200);

  @override
  Future<DeezerSearchResult> search(String query, {DeezerSearchType type = DeezerSearchType.all, bool enrich = true}) async {
    lastEnrichFlag = enrich;
    return const DeezerSearchResult(tracks: [_raw]);
  }

  @override
  Future<DeezerSearchResult> enrichSearchResult(DeezerSearchResult raw, String query, {DeezerSearchType type = DeezerSearchType.all}) async {
    await enrichGate.future;
    return const DeezerSearchResult(tracks: [_rich]);
  }
}

void main() {
  test('la búsqueda pinta antes de enriquecer y luego completa', () async {
    final api = _TwoPhaseApi();
    final container = ProviderContainer(overrides: [deezerApiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);
    final sub = container.listen(searchProvider, (_, _) {});
    addTearDown(sub.close);

    container.read(searchProvider.notifier).setQuery('hola');
    await Future<void>.delayed(const Duration(milliseconds: 650));

    var state = container.read(searchProvider);
    expect(api.lastEnrichFlag, isFalse);
    expect(state.isLoading, isFalse);
    expect(state.result.tracks.single.title, 'Cruda');

    api.enrichGate.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    state = container.read(searchProvider);
    expect(state.result.tracks.single.title, 'Enriquecida');
  });
}
