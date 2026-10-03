import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:syncora_player/data/apis/deezer_api.dart';
import 'package:syncora_player/data/apis/deezer_provider.dart';
import 'package:syncora_player/data/local_db/database_provider.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';
import 'package:syncora_player/features/discover/discover_feed.dart';
import 'package:syncora_player/features/discover/discover_screen.dart';
import 'package:syncora_player/features/player/player_providers.dart';
import 'package:syncora_player/features/player/syncora_player_controller.dart';

import '../player/syncora_player_controller_test.dart' show FakeAudioEngine, TestableExtractionService;

class _ChartApi extends DeezerApi {
  @override
  Future<List<DeezerTrack>> getTopCharts() async => [
        for (var i = 1; i <= 6; i++)
          DeezerTrack(
            id: i,
            title: 'Canción $i',
            artistName: 'Artista $i',
            artistId: i,
            albumTitle: 'Álbum',
            albumId: 1,
            coverUrl: '',
            durationSec: 200,
            previewUrl: 'https://cdnt-preview.dzcdn.net/$i.mp3',
          ),
      ];
}

void main() {
  late SyncoraDatabase db;

  setUp(() {
    db = SyncoraDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  });

  tearDown(() => db.close());

  for (final (label, size) in [('móvil', const Size(400, 860)), ('escritorio', const Size(1280, 800))]) {
    testWidgets('Descubrir carga la primera tarjeta en $label', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = SyncoraPlayerController(
        engine: FakeAudioEngine(),
        extractionService: TestableExtractionService(),
      )..init();

      await tester.pumpWidget(ProviderScope(
        overrides: [
          syncoraDatabaseProvider.overrideWithValue(db),
          syncoraPlayerControllerProvider.overrideWith((ref) => controller),
          deezerApiProvider.overrideWithValue(_ChartApi()),
          previewEngineFactoryProvider.overrideWithValue(FakeAudioEngine.new),
          previewFileCacheFactoryProvider.overrideWithValue(null),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(routes: [
            GoRoute(path: '/', builder: (_, _) => const Scaffold(body: DiscoverScreen())),
          ]),
        ),
      ));

      for (var i = 0; i < 20 && find.text('Canción 1').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Canción'), findsWidgets);

      // El ProviderScope libera el controlador al desmontarse.
      await tester.pumpWidget(const SizedBox());
    });
  }
}
