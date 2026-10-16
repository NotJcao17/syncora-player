import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/apis/lrclib_api.dart';

/// Responde en orden la lista de respuestas que se le da, una por petición.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.responses);

  final List<_Reply> responses;
  final List<String> paths = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    paths.add(options.path);
    final reply = responses.removeAt(0);
    return ResponseBody.fromString(jsonEncode(reply.body), reply.status, headers: {
      Headers.contentTypeHeader: ['application/json'],
      if (reply.retryAfter != null) 'retry-after': [reply.retryAfter!],
    });
  }

  @override
  void close({bool force = false}) {}
}

class _Reply {
  const _Reply(this.status, this.body, {this.retryAfter});
  final int status;
  final Object body;
  final String? retryAfter;
}

const _rateLimited = _Reply(429, {'message': 'Too many requests. Please retry later.'}, retryAfter: '1');
const _notFound = _Reply(404, {'message': 'Failed to find specified track'});
const _found = _Reply(200, {
  'trackName': "Don't Stop Me Now",
  'plainLyrics': 'Tonight I\'m gonna have myself',
  'syncedLyrics': '[00:01.00] Tonight I\'m gonna have myself',
});

void main() {
  late List<Duration> waits;

  LRCLibApi buildApi(_ScriptedAdapter adapter) => LRCLibApi(
        dio: Dio(BaseOptions(baseUrl: 'https://lrclib.net/api'))..httpClientAdapter = adapter,
        sleep: (d) async => waits.add(d),
      );

  Future<LRCLibResult?> fetch(LRCLibApi api) => api.getLyrics(
        cacheKey: 'queen',
        trackTitle: "Don't Stop Me Now",
        artistName: 'Queen',
        durationSec: 212,
      );

  setUp(() => waits = []);

  test('un 429 que no se recupera no deja la canción sin letra en caché', () async {
    final adapter = _ScriptedAdapter([
      for (var i = 0; i < LRCLibApi.maxAttempts; i++) _rateLimited, // /get
      for (var i = 0; i < LRCLibApi.maxAttempts; i++) _rateLimited, // /search
      _found, // al volver a abrir la letra
    ]);
    final api = buildApi(adapter);

    expect(await fetch(api), isNull);
    final second = await fetch(api);

    expect(second?.hasSynced, isTrue, reason: 'el fallo temporal no quedó en caché');
  });

  test('ante un 429 reintenta respetando Retry-After', () async {
    final adapter = _ScriptedAdapter([_rateLimited, _rateLimited, _found]);
    final api = buildApi(adapter);

    final result = await fetch(api);

    expect(result?.hasSynced, isTrue);
    expect(adapter.paths, ['/get', '/get', '/get']);
    expect(waits.length, 2);
    expect(waits.every((d) => d >= const Duration(seconds: 1)), isTrue);
  });

  test('una canción que de verdad no existe sí queda en caché', () async {
    final adapter = _ScriptedAdapter([_notFound, const _Reply(200, [])]);
    final api = buildApi(adapter);

    expect(await fetch(api), isNull);
    expect(await fetch(api), isNull);
    expect(adapter.paths, ['/get', '/search'], reason: 'la segunda vez sale de la caché');
  });

  test('si /get no la encuentra y /search falla, tampoco se cachea', () async {
    final adapter = _ScriptedAdapter([
      _notFound,
      for (var i = 0; i < LRCLibApi.maxAttempts; i++) _rateLimited,
      _found,
    ]);
    final api = buildApi(adapter);

    expect(await fetch(api), isNull);
    expect((await fetch(api))?.hasSynced, isTrue);
  });
}
