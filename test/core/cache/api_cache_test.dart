import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/cache/api_cache.dart';

void main() {
  late Directory tempDir;
  late ApiCache cache;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('api_cache_test');
    cache = ApiCache(directory: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('devuelve lo guardado mientras no venza el TTL', () async {
    await cache.write('k', [1, 2, 3]);
    expect(await cache.read('k', const Duration(minutes: 5)), [1, 2, 3]);
  });

  test('descarta lo guardado cuando el TTL ya venció', () async {
    await cache.write('k', [1, 2, 3]);
    expect(await cache.read('k', Duration.zero), isNull);
  });

  test('fetch no llama a la red si hay algo fresco en caché', () async {
    var calls = 0;
    Future<List<int>> fetcher() async {
      calls++;
      return [calls];
    }

    final first = await cache.fetch<List<int>>(
      key: 'nums',
      ttl: const Duration(minutes: 5),
      fetcher: fetcher,
      encode: (v) => v,
      decode: (json) => (json as List).cast<int>(),
    );
    final second = await cache.fetch<List<int>>(
      key: 'nums',
      ttl: const Duration(minutes: 5),
      fetcher: fetcher,
      encode: (v) => v,
      decode: (json) => (json as List).cast<int>(),
    );

    expect(first, [1]);
    expect(second, [1]);
    expect(calls, 1);
  });

  test('si la red falla, devuelve la copia vencida en vez de reventar', () async {
    await cache.write('nums', [42]);

    final result = await cache.fetch<List<int>>(
      key: 'nums',
      // TTL cero: obliga a ir a la red, que va a fallar.
      ttl: Duration.zero,
      fetcher: () async => throw const SocketException('sin red'),
      encode: (v) => v,
      decode: (json) => (json as List).cast<int>(),
    );

    expect(result, [42]);
  });

  test('sin caché previa y con la red caída, propaga el error', () async {
    expect(
      () => cache.fetch<List<int>>(
        key: 'vacio',
        ttl: const Duration(minutes: 5),
        fetcher: () async => throw const SocketException('sin red'),
        encode: (v) => v,
        decode: (json) => (json as List).cast<int>(),
      ),
      throwsA(isA<SocketException>()),
    );
  });

  test('un archivo corrupto se trata como "no hay caché", no como un crash', () async {
    await cache.write('roto', [1]);
    // Simula el archivo a medio escribir que dejaba un cierre abrupto.
    final file = File('${tempDir.path}/roto.json');
    await file.writeAsString('{"cached_at": 123, "payl');

    // La capa en memoria todavía tiene el valor bueno; una instancia nueva
    // es la que realmente lee el disco.
    final fresh = ApiCache(directory: tempDir);
    expect(await fresh.read('roto', const Duration(minutes: 5)), isNull);
  });

  test('clear borra todo, memoria y disco', () async {
    await cache.write('k', [1]);
    await cache.clear();
    expect(await cache.read('k', const Duration(minutes: 5)), isNull);
  });
}
