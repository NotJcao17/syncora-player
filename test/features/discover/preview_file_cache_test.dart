import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/discover/preview_file_cache.dart';
import 'package:syncora_player/features/discover/preview_player.dart';

import '../player/syncora_player_controller_test.dart' show FakeAudioEngine;

/// Servidor falso: responde bytes para URLs "buenas" y 403 para las caducadas.
class _FakeAdapter implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests++;
    if (options.uri.path.contains('caducada')) {
      return ResponseBody.fromBytes(const [], 403);
    }
    return ResponseBody.fromBytes(List<int>.filled(1000, 7), 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;
  late _FakeAdapter adapter;
  late PreviewFileCache cache;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('preview_cache_test');
    adapter = _FakeAdapter();
    cache = PreviewFileCache(
      dio: Dio(BaseOptions(responseType: ResponseType.bytes))..httpClientAdapter = adapter,
      baseDir: () async => tmp,
    );
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('descarga a archivo una sola vez aunque se pida dos veces a la vez', () async {
    final results = await Future.wait([cache.fetch(1, 'https://x/1.mp3'), cache.fetch(1, 'https://x/1.mp3')]);
    expect(results[0], isNotNull);
    expect(results[0], results[1]);
    expect(adapter.requests, 1);
    expect(await File(results[0]!).length(), 1000);
    expect(await cache.fetch(1, 'https://x/1.mp3'), results[0], reason: 'ya en disco: sin pedir de nuevo');
    expect(adapter.requests, 1);
  });

  test('una URL caducada devuelve null, sin archivo a medias', () async {
    expect(await cache.fetch(2, 'https://x/caducada.mp3'), isNull);
    final dir = Directory('${tmp.path}/syncora_previews');
    final files = await dir.exists() ? await dir.list().toList() : <FileSystemEntity>[];
    expect(files, isEmpty);
  });

  test('prune borra lo lejano y clear lo borra todo', () async {
    final a = (await cache.fetch(1, 'https://x/1.mp3'))!;
    final b = (await cache.fetch(2, 'https://x/2.mp3'))!;
    await cache.prune({2});
    expect(await File(a).exists(), isFalse);
    expect(await File(b).exists(), isTrue);
    await cache.clear();
    expect(await File(b).exists(), isFalse);
  });

  test('el reproductor usa el archivo local y refresca la URL si la vieja caducó', () async {
    final engine = FakeAudioEngine();
    final player = PreviewPlayer(
      engineFactory: () => engine,
      refreshUrl: (_) async => 'https://x/fresca.mp3',
      fetchLocal: cache.fetch,
    );
    addTearDown(player.dispose);

    expect(await player.play(5, 'https://x/caducada.mp3'), isTrue);
    expect(engine.lastLocalSourcePath, endsWith('preview_5.mp3'));
    expect(engine.setUrlCallCount, 0, reason: 'nada de streaming si hay archivo');
  });

  test('sin archivo posible cae al streaming de siempre', () async {
    final engine = FakeAudioEngine();
    final player = PreviewPlayer(
      engineFactory: () => engine,
      refreshUrl: (_) async => 'https://x/caducada-tambien.mp3',
      fetchLocal: cache.fetch,
    );
    addTearDown(player.dispose);

    await player.play(6, 'https://x/caducada.mp3');
    expect(engine.setLocalSourceCallCount, 0);
    expect(engine.setUrlCallCount, greaterThan(0));
  });
}
