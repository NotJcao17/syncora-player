import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:syncora_player/core/storage/legacy_documents_migration.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';

import '../../features/auth/local_mode_provider_test.dart' show FakeLocalModeStorage;

/// Windows guardaba todo en Documentos; ahora va a `%LOCALAPPDATA%`. La
/// mudanza mueve los archivos y reescribe las rutas absolutas guardadas.
void main() {
  SyncoraDatabase memoryDb() =>
      SyncoraDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));

  group('rebasePath', () {
    const from = r'C:\Users\ana\Documents';
    const to = r'C:\Users\ana\AppData\Local\com.syncora\Syncora Player';

    test('cambia el prefijo con cualquier separador', () {
      expect(rebasePath(r'C:\Users\ana\Documents\syncora\custom_images\a.jpg', from: from, to: to),
          r'C:\Users\ana\AppData\Local\com.syncora\Syncora Player\syncora\custom_images\a.jpg');
      expect(rebasePath(r'C:\Users\ana\Documents/syncora/downloads/1.mp4', from: from, to: to),
          r'C:\Users\ana\AppData\Local\com.syncora\Syncora Player/syncora/downloads/1.mp4');
    });

    test('no toca URLs ni carpetas que solo comparten el inicio del nombre', () {
      expect(rebasePath('https://cdn.example.com/a.jpg', from: from, to: to), isNull);
      expect(rebasePath(r'C:\Users\ana\Documents2\x.jpg', from: from, to: to), isNull);
    });
  });

  group('moveLegacyEntries', () {
    late Directory root;
    late Directory from;
    late Directory to;

    setUp(() {
      root = Directory.systemTemp.createTempSync('syncora_move_');
      from = Directory(p.join(root.path, 'Documents'))..createSync();
      to = Directory(p.join(root.path, 'AppData'))..createSync();
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('mueve la base, las cachés y la carpeta syncora, y deja lo ajeno', () async {
      File(p.join(from.path, 'syncora_local.sqlite')).writeAsStringSync('db');
      File(p.join(from.path, 'repair_state.json')).writeAsStringSync('{}');
      Directory(p.join(from.path, 'api_cache')).createSync();
      File(p.join(from.path, 'syncora', 'downloads', '1.mp4'))
        ..createSync(recursive: true)
        ..writeAsStringSync('audio');
      File(p.join(from.path, 'tarea.docx')).writeAsStringSync('del usuario');

      final moved = await moveLegacyEntries(from: from, to: to);

      expect(moved, containsAll(['syncora_local.sqlite', 'repair_state.json', 'api_cache', 'syncora']));
      expect(File(p.join(to.path, 'syncora', 'downloads', '1.mp4')).readAsStringSync(), 'audio');
      expect(File(p.join(from.path, 'syncora_local.sqlite')).existsSync(), isFalse);
      expect(File(p.join(from.path, 'tarea.docx')).existsSync(), isTrue, reason: 'no es de Syncora');
    });

    test('nunca pisa lo que ya está en la carpeta nueva', () async {
      File(p.join(from.path, 'syncora_local.sqlite')).writeAsStringSync('vieja');
      File(p.join(to.path, 'syncora_local.sqlite')).writeAsStringSync('nueva');

      final moved = await moveLegacyEntries(from: from, to: to);

      expect(moved, isEmpty);
      expect(File(p.join(to.path, 'syncora_local.sqlite')).readAsStringSync(), 'nueva');
    });
  });

  test('rebaseMovedPaths reescribe los JSON de syncora y la foto del modo local', () async {
    const from = r'C:\Users\ana\Documents';
    const to = r'C:\Users\ana\AppData\Local\com.syncora\Syncora Player';
    final root = Directory.systemTemp.createTempSync('syncora_rebase_');
    addTearDown(() => root.deleteSync(recursive: true));

    final index = File(p.join(root.path, 'syncora', 'covers', 'index.json'))..createSync(recursive: true);
    index.writeAsStringSync(jsonEncode({
      'https://cdn/a.jpg': {'path': '$from\\syncora\\covers\\1.jpg', 'size': 10},
    }));

    final localMode = FakeLocalModeStorage();
    await localMode.setAvatarImagePath('$from\\syncora\\custom_images\\yo.jpg');

    await rebaseMovedPaths(
      from: from,
      to: to,
      dataDir: root,
      openDatabase: memoryDb,
      localModeStorage: localMode,
    );

    final json = jsonDecode(index.readAsStringSync()) as Map<String, dynamic>;
    expect((json['https://cdn/a.jpg'] as Map)['path'], '$to\\syncora\\covers\\1.jpg');
    expect(await localMode.getAvatarImagePath(), '$to\\syncora\\custom_images\\yo.jpg');
  });

  test('rebaseDatabasePaths cambia solo las rutas de la carpeta vieja', () async {
    const from = r'C:\Users\ana\Documents';
    const to = r'C:\Users\ana\AppData\Local\com.syncora\Syncora Player';
    final db = memoryDb();
    addTearDown(db.close);

    await db.downloadedTrackDao.insertOrUpdate(DownloadedTracksCompanion.insert(
      trackId: 1,
      artistId: 1,
      albumId: 1,
      title: 'Pista',
      artistName: 'Artista',
      albumName: 'Álbum',
      coverUrl: 'https://cdn/a.jpg',
      localAudioPath: '$from/syncora/downloads/1.mp4',
      localCoverPath: const Value('$from/syncora/covers/1.jpg'),
      durationMs: 1000,
      downloadState: const Value(2),
    ));
    final local = await db.playlistDao.createPlaylist(title: 'Local');
    final localPlaylist = (await db.playlistDao.getPlaylistById(local))!;
    await db.playlistDao.updatePlaylist(localPlaylist.copyWith(coverUrl: const Value('$from\\syncora\\custom_images\\a.jpg')));
    final remote = await db.playlistDao.createPlaylist(title: 'Remota');
    final remotePlaylist = (await db.playlistDao.getPlaylistById(remote))!;
    await db.playlistDao.updatePlaylist(remotePlaylist.copyWith(coverUrl: const Value('https://r2/x.jpg')));

    await rebaseDatabasePaths(db, from: from, to: to);

    final track = (await db.downloadedTrackDao.getAll()).single;
    expect(track.localAudioPath, '$to/syncora/downloads/1.mp4');
    expect(track.localCoverPath, '$to/syncora/covers/1.jpg');
    expect((await db.playlistDao.getPlaylistById(local))!.coverUrl, '$to\\syncora\\custom_images\\a.jpg');
    expect((await db.playlistDao.getPlaylistById(remote))!.coverUrl, 'https://r2/x.jpg');
  });
}
