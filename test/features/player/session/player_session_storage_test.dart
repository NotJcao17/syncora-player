import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/session/player_session_storage.dart';

void main() {
  group('PlayerSessionStorage: escritura atómica y single-flight', () {
    late Directory dir;
    late File file;
    late PlayerSessionStorage storage;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('syncora_session_test');
      file = File('${dir.path}/session.json');
      storage = PlayerSessionStorage(overrideFile: file);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> save(int positionSeconds) => storage.saveSession(
          currentTrack: SyncoraTrack(id: 't$positionSeconds', title: 'T'),
          currentOrigin: QueueOrigin.auto,
          manualQueue: const [SyncoraTrack(id: 'm1', title: 'M1')],
          autoQueue: const [],
          originalContextTracks: const [],
          history: const [],
          positionSeconds: positionSeconds,
          repeatMode: SyncoraRepeatMode.off,
          shuffle: false,
          activeContextId: 'playlist_7',
        );

    test('una ráfaga de guardados deja un archivo válido con el último estado', () async {
      // El guardado periódico de posición (cada 5s) + los eventos discretos
      // hacen que dos guardados se solapen con facilidad. Con la escritura
      // directa anterior (truncar y volcar sobre el archivo final) eso podía
      // dejar un JSON a medias, y `loadSession` no distingue un archivo
      // corrupto de "no hay sesión": se perdía la sesión entera.
      await Future.wait([for (var i = 1; i <= 50; i++) save(i)]);

      final onDisk = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(onDisk['positionSeconds'], 50);

      final loaded = await storage.loadSession();
      expect(loaded, isNotNull);
      expect(loaded!.positionSeconds, 50);
      expect(loaded.activeContextId, 'playlist_7');
      expect(loaded.manualQueue.single.id, 'm1');
    });

    test('no deja el temporal atrás tras escribir', () async {
      await save(12);
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });
  });
}
