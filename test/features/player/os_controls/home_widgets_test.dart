import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/navigation/widget_links.dart';
import 'package:syncora_player/features/player/audio_engine/audio_engine_state.dart';
import 'package:syncora_player/data/local_db/daos/playlist_dao.dart';
import 'package:syncora_player/data/local_db/daos/saved_album_dao.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/features/player/os_controls/home_widgets.dart';
import 'package:syncora_player/features/player/os_controls/syncora_audio_handler.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/syncora_player_controller.dart';

import '../mini_player_test.dart' show FakeAudioEngine, FakeExtractionService;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('widget "Reproduciendo"', () {
    test('solo se publica cuando cambia la pista o play/pausa, nunca por la posición', () async {
      final sent = <NowPlayingWidgetState>[];
      final publisher = NowPlayingWidgetPublisher(
        send: (s, _) async => sent.add(s),
        resolveCover: (art) async => '/cache/${art.pathSegments.last}',
      );
      final engine = FakeAudioEngine();
      final controller = SyncoraPlayerController(engine: engine, extractionService: FakeExtractionService());
      final handler = SyncoraAudioHandler(controller)..widgetPublisher = publisher;
      await pumpEventQueue();
      sent.clear();

      await controller.setQueue([
        SyncoraTrack(id: 'a', title: 'Uno', artist: 'X', artUri: Uri.parse('https://cdn-images.dzcdn.net/a.jpg')),
        const SyncoraTrack(id: 'b', title: 'Dos', artist: 'Y'),
      ], autoplay: false);
      await pumpEventQueue();
      expect(sent.map((s) => s.title), ['Uno']);

      for (var i = 1; i <= 10; i++) {
        engine.emitState(AudioEngineState.initial.copyWith(processingState: AudioProcessingState.ready, position: Duration(seconds: i)));
      }
      await pumpEventQueue();
      expect(sent, hasLength(1), reason: 'los ticks de posición no repintan el widget');

      await controller.skipToNext();
      await pumpEventQueue();
      expect(sent.last.title, 'Dos');
      handler.widgetPublisher = null;
    });

    test('una portada que se resuelve tarde no pisa la pista nueva', () async {
      final calls = <(String, String?)>[];
      final slow = Completer<String?>();
      final publisher = NowPlayingWidgetPublisher(
        send: (s, cover) async => calls.add((s.title, cover)),
        resolveCover: (art) => art.path.contains('lenta') ? slow.future : Future.value('/rapida.jpg'),
      );
      publisher.onState(NowPlayingWidgetState.of(
        SyncoraTrack(id: '1', title: 'Lenta', artUri: Uri.parse('https://x.dzcdn.net/lenta.jpg')),
        playing: true,
      ));
      publisher.onState(NowPlayingWidgetState.of(
        SyncoraTrack(id: '2', title: 'Rápida', artUri: Uri.parse('https://x.dzcdn.net/rapida.jpg')),
        playing: true,
      ));
      await pumpEventQueue();
      slow.complete('/lenta.jpg');
      await pumpEventQueue();
      expect(calls, [('Rápida', '/rapida.jpg')]);
    });
  });

  group('widget de playlist o álbum', () {
    late SyncoraDatabase db;
    setUp(() => db = SyncoraDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true)));
    tearDown(() => db.close());

    test('la lista ofrece Tus me gusta, las playlists y los álbumes, con portada', () async {
      final playlists = PlaylistDao(db);
      final albums = SavedAlbumDao(db);
      await playlists.createPlaylist(title: 'Propia', coverUrl: 'https://syncora-images.x.workers.dev/p.jpg');
      final sinPortada = await playlists.createPlaylist(title: 'Sin portada');
      await playlists.appendTracksBatch(sinPortada, [
        PlaylistTracksCompanion.insert(
          playlistId: sinPortada, trackId: 1, artistId: 1, albumId: 9, title: 't', artistName: 'a',
          albumName: 'al', coverUrl: 'https://cdn-images.dzcdn.net/t.jpg', durationMs: 1000,
        ),
      ]);
      await playlists.getLikedPlaylist();
      await albums.saveAlbum(albumId: 302127, title: 'Discovery', artistName: 'Daft Punk', coverUrl: 'https://cdn-images.dzcdn.net/d.jpg');

      final items = buildWidgetCollections(
        await playlists.getAllPlaylists(),
        await playlists.watchPlaylistSummaries().first,
        await albums.getAllSavedAlbums(),
      );
      expect(items.first.title, 'Tus me gusta');
      final byTitle = {for (final i in items) i.title: i};
      expect(byTitle['Propia']!.cover, 'https://syncora-images.x.workers.dev/p.jpg');
      expect(byTitle['Sin portada']!.cover, 'https://cdn-images.dzcdn.net/t.jpg');
      expect(byTitle['Discovery']!.kind, 'album');
      expect(byTitle['Discovery']!.id, '302127');
      expect(byTitle['Discovery']!.subtitle, 'Daft Punk');
    });

    test('la biblioteca se publica una vez por cambio real, no por cada evento', () async {
      final playlists = PlaylistDao(db);
      final sent = <int>[];
      final publisher = LibraryWidgetPublisher(
        playlistDao: playlists,
        savedAlbumDao: SavedAlbumDao(db),
        send: (items) async => sent.add(items.length),
        debounce: const Duration(milliseconds: 20),
      )..start();
      addTearDown(publisher.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final before = sent.length;
      await playlists.createPlaylist(title: 'Nueva');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(sent.length, before + 1);
      await playlists.touchLastPlayed((await playlists.getAllPlaylists()).first.id);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(sent.length, before + 1, reason: 'escuchar una playlist no cambia lo que muestra el widget');
    });
  });

  test('enlaces de los widgets', () {
    expect(widgetRouteFromUri(Uri.parse('syncoraplayer://widget/player')), '/player');
    expect(widgetRouteFromUri(Uri.parse('syncoraplayer://widget/playlist/12')), '/playlist/12');
    expect(widgetRouteFromUri(Uri.parse('syncoraplayer://widget/album/302127')), '/album/302127');
    expect(widgetRouteFromUri(Uri.parse('syncoraplayer://widget/playlist/abc')), isNull);
    expect(widgetRouteFromUri(Uri.parse('syncoraplayer://playlist/12')), isNull);
  });
}
