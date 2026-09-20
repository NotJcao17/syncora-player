import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/local_db/duplicate_repair.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';

/// La reparación de duplicados tiene que correr **una sola vez**: la causa ya
/// está cerrada (guarda de reentrancia en `SyncService`), esto solo limpia las
/// instalaciones que quedaron sucias con versiones anteriores.
void main() {
  late SyncoraDatabase db;
  late Directory tempDir;
  late DuplicateRepair repair;

  setUp(() async {
    db = SyncoraDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    tempDir = await Directory.systemTemp.createTemp('repair_test');
    repair = DuplicateRepair(playlistDao: db.playlistDao, directory: tempDir);
  });

  tearDown(() async {
    await db.close();
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('la primera pasada repara y la segunda ya no hace nada', () async {
    await db.playlistDao.createPlaylist(title: 'Importada', remoteId: 'r1');
    await db.playlistDao.createPlaylist(title: 'Importada', remoteId: 'r1');

    final first = await repair.runOnce();
    expect(first, isNotNull);
    expect((await db.playlistDao.getAllPlaylists()).where((p) => p.remoteId == 'r1').length, 1);

    // Si volviera a correr, un duplicado nuevo se limpiaría solo; el objetivo
    // es justamente que NO lo haga.
    await db.playlistDao.createPlaylist(title: 'Importada', remoteId: 'r1');
    final second = await repair.runOnce();

    expect(second, isNull);
    expect((await db.playlistDao.getAllPlaylists()).where((p) => p.remoteId == 'r1').length, 2);
  });

  test('una instancia nueva respeta el marcador dejado en disco', () async {
    await repair.runOnce();

    final fresh = DuplicateRepair(playlistDao: db.playlistDao, directory: tempDir);
    expect(await fresh.runOnce(), isNull);
  });

  test('un marcador corrupto no impide reparar', () async {
    await File('${tempDir.path}/repair_state.json').writeAsString('{no es json');
    await db.playlistDao.createPlaylist(title: 'Importada', remoteId: 'r1');
    await db.playlistDao.createPlaylist(title: 'Importada', remoteId: 'r1');

    expect(await repair.runOnce(), isNotNull);
    expect((await db.playlistDao.getAllPlaylists()).where((p) => p.remoteId == 'r1').length, 1);
  });
}
