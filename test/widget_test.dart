import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/app.dart';

import 'package:syncora_player/data/apis/deezer_api.dart';
import 'package:syncora_player/data/apis/deezer_provider.dart';
import 'package:syncora_player/data/models/deezer/deezer_playlist.dart';
import 'package:syncora_player/data/models/deezer/deezer_search_result.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';

class MockDeezerApi extends DeezerApi {
  @override
  Future<DeezerSearchResult> search(String query, {DeezerSearchType type = DeezerSearchType.all}) async {
    return const DeezerSearchResult();
  }

  @override
  Future<List<DeezerPlaylist>> getEditorialPlaylists() async {
    return const [];
  }

  @override
  Future<List<DeezerTrack>> getTopCharts() async {
    return const [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SyncoraApp smoke test', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = ProviderContainer(
      overrides: [
        deezerApiProvider.overrideWithValue(MockDeezerApi()),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SyncoraApp(),
      ),
    );

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.byType(SyncoraApp), findsOneWidget);

    container.dispose();
    await tester.pump();
  });
}
