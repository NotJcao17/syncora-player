import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/daos/downloaded_track_dao.dart';
import 'package:syncora_player/data/local_db/daos/folder_dao.dart';
import 'package:syncora_player/data/local_db/daos/playlist_dao.dart';
import 'package:syncora_player/data/local_db/daos/saved_album_dao.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/features/player/os_controls/android_auto_browser.dart';
import 'package:syncora_player/features/player/os_controls/syncora_audio_handler.dart';
import 'package:syncora_player/features/player/syncora_player_controller.dart';

import '../mini_player_test.dart' show FakeAudioEngine, FakeExtractionService;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncoraDatabase db;
  late PlaylistDao playlists;
  late SavedAlbumDao albums;
  late FolderDao folders;
  late DownloadedTrackDao downloads;

  setUp(() {
    db = SyncoraDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    playlists = PlaylistDao(db);
    albums = SavedAlbumDao(db);
    folders = FolderDao(db);
    downloads = DownloadedTrackDao(db);
  });
  tearDown(() => db.close());

  AndroidAutoBrowser browser() => AndroidAutoBrowser(
        playlistDao: playlists,
        savedAlbumDao: albums,
        folderDao: folders,
        downloadedTrackDao: downloads,
      );

  Future<void> addTracks(int playlistId, int count) async {
    await playlists.appendTracksBatch(playlistId, [
      for (var i = 0; i < count; i++)
        PlaylistTracksCompanion.insert(
          playlistId: playlistId,
          trackId: 1000 + i,
          artistId: 1,
          albumId: 1,
          title: 'Canción $i',
          artistName: 'Artista',
          albumName: 'Álbum',
          coverUrl: 'https://cdn-images.dzcdn.net/images/cover/$i/250x250.jpg',
          durationMs: 180000,
        ),
    ]);
  }

  Future<void> playedAt(int playlistId, DateTime at) =>
      (db.update(db.playlists)..where((t) => t.id.equals(playlistId))).write(PlaylistsCompanion(lastPlayedAt: Value(at)));

  test('la raíz son tres pestañas: Inicio, Biblioteca y Descargas', () async {
    final root = await browser().children(AudioService.browsableRootId);
    expect(root.map((i) => i.title), ['Inicio', 'Biblioteca', 'Descargas']);
    expect(root.every((i) => i.playable == false), isTrue, reason: 'Android Auto solo hace pestañas si todas son navegables');
  });

  test('Inicio: lo escuchado reciente primero (playlists y álbumes mezclados) y luego Tu música', () async {
    final liked = await playlists.getLikedPlaylist();
    final old = await playlists.createPlaylist(title: 'Vieja');
    final fresh = await playlists.createPlaylist(title: 'Nueva');
    await playlists.createPlaylist(title: 'Fijada', isPinned: true);
    await playlists.createPlaylist(title: 'Nunca escuchada');
    await playedAt(old, DateTime(2026, 1, 1));
    await playedAt(fresh, DateTime(2026, 3, 1));
    await albums.saveAlbum(albumId: 77, title: 'Disco', artistName: 'Banda', coverUrl: 'https://cdn-images.dzcdn.net/a.jpg');
    await (db.update(db.savedAlbums)..where((t) => t.albumId.equals(77)))
        .write(SavedAlbumsCompanion(lastPlayedAt: Value(DateTime(2026, 2, 1))));

    final home = await browser().children(AndroidAutoBrowser.home);
    expect(home.map((i) => i.title), ['Nueva', 'Disco', 'Vieja', 'Tus me gusta', 'Fijada']);
    String? group(MediaItem i) => i.extras?['android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT'] as String?;
    expect(home.take(3).map(group).toSet(), {'Escuchado recientemente'});
    expect(home.skip(3).map(group).toSet(), {'Tu música'});
    expect(home[3].id, '${AndroidAutoBrowser.playlistPrefix}${liked.id}');
    expect(home[1].id, '${AndroidAutoBrowser.albumPrefix}77');
  });

  test('Biblioteca: Tus me gusta, playlists sueltas, carpetas y álbumes; lo de una carpeta va dentro', () async {
    await playlists.getLikedPlaylist();
    final folderId = await folders.createFolder(name: 'Gym');
    await playlists.createPlaylist(title: 'Suelta');
    await playlists.createPlaylist(title: 'En carpeta', folderId: folderId);
    await albums.saveAlbum(albumId: 5, title: 'Disco', artistName: 'Banda', coverUrl: '');

    final b = browser();
    final lib = await b.children(AndroidAutoBrowser.library);
    expect(lib.map((i) => i.title), ['Tus me gusta', 'Suelta', 'Gym', 'Disco']);
    final inFolder = await b.children('${AndroidAutoBrowser.folderPrefix}$folderId');
    expect(inFolder.map((i) => i.title), ['En carpeta']);
  });

  test('las portadas van como content:// del proveedor (Android Auto no carga URLs)', () async {
    final id = await playlists.createPlaylist(title: 'Con canciones');
    await addTracks(id, 2);
    final lib = await browser().children(AndroidAutoBrowser.library);
    final art = lib.firstWhere((i) => i.title == 'Con canciones').artUri!;
    expect(art.scheme, 'content');
    expect(art.host, AutoArt.authority);
    expect(art.pathSegments.first, 'img');
    final decoded = utf8.decode(base64Url.decode(base64Url.normalize(art.pathSegments[1])));
    expect(decoded, 'https://cdn-images.dzcdn.net/images/cover/0/250x250.jpg', reason: 'sin portada propia, la primera de sus canciones');
    expect(AutoArt.of('/data/user/0/app/cover.jpg')!.pathSegments.first, 'file');
    expect(AutoArt.of('assets/x.png'), isNull);
    expect(AutoArt.of('paint:FF6366F1,FF9333EA;heart')!.pathSegments.first, 'paint', reason: 'degradados y Tus me gusta los dibuja el proveedor');
  });

  test('una playlist abre con "Reproducir en aleatorio" y se corta en 400 filas; tocar usa la lista entera', () async {
    final id = await playlists.createPlaylist(title: 'Enorme');
    await addTracks(id, 450);
    final b = browser();
    final items = await b.children('${AndroidAutoBrowser.playlistPrefix}$id');
    expect(items.first.title, 'Reproducir en aleatorio');
    expect(items.first.playable, isTrue);
    expect(items.length, 1 + AndroidAutoBrowser.maxListedTracks);
    expect(items[1].id, '${AndroidAutoBrowser.playlistPrefix}$id|0');

    final tap = await b.resolvePlay(items[11].id);
    expect(tap!.tracks.length, 450);
    expect(tap.startIndex, 10);
    expect(tap.shuffle, isFalse);
    expect(tap.contextId, 'playlist_$id');

    final shuffle = await b.resolvePlay(items.first.id);
    expect(shuffle!.shuffle, isTrue);
    expect(shuffle.tracks.length, 450);
  });

  test('tocar "Reproducir en aleatorio" activa el aleatorio y pone toda la playlist', () async {
    final id = await playlists.createPlaylist(title: 'Mix');
    await addTracks(id, 5);
    final controller = SyncoraPlayerController(engine: FakeAudioEngine(), extractionService: FakeExtractionService());
    final handler = SyncoraAudioHandler(controller, playlistDao: playlists, savedAlbumDao: albums, folderDao: folders);

    await handler.playFromMediaId('${AndroidAutoBrowser.playlistPrefix}$id|shuffle');
    expect(controller.state.isShuffle, isTrue);
    expect(controller.state.activeContextId, 'playlist_$id');
    final all = {controller.state.currentTrack!.id, ...controller.state.manualQueue.map((t) => t.id), ...controller.state.autoQueue.map((t) => t.id)};
    expect(all.length, 5);
    expect((await playlists.getPlaylistById(id))!.lastPlayedAt, isNotNull, reason: 'cuenta para Escuchado recientemente');
  });
}
