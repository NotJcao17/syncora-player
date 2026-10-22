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

  // Ronda 10: al volver a la pestaña Buscar el campo está vacío pero el estado
  // conserva la última consulta; tocar esa misma búsqueda reciente no buscaba.
  test('tocar una búsqueda reciente igual a la última consulta vuelve a buscar', () async {
    final api = _CountingApi();
    final container = ProviderContainer(overrides: [deezerApiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);
    final sub = container.listen(searchProvider, (_, _) {});
    addTearDown(sub.close);
    final notifier = container.read(searchProvider.notifier);

    notifier.setQuery('feo');
    await Future<void>.delayed(const Duration(milliseconds: 650));
    expect(api.searches, 1);

    notifier.searchNow('feo');
    expect(container.read(searchProvider).isLoading, isTrue);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(api.searches, 2);
    expect(container.read(searchProvider).isLoading, isFalse);
  });
}

class _CountingApi extends DeezerApi {
  int searches = 0;

  @override
  Future<DeezerSearchResult> search(String query, {DeezerSearchType type = DeezerSearchType.all, bool enrich = true}) async {
    searches++;
    return const DeezerSearchResult();
  }

  @override
  Future<DeezerSearchResult> enrichSearchResult(DeezerSearchResult raw, String query, {DeezerSearchType type = DeezerSearchType.all}) async =>
      raw;
}
