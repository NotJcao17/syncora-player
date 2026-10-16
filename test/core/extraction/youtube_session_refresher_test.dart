import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/extraction/dart_fetch_bridge.dart';
import 'package:syncora_player/core/extraction/youtube_session_refresher.dart';

/// Guarda la cabecera `cookie` de cada petición y responde con un `set-cookie`.
class _CookieAdapter implements HttpClientAdapter {
  final List<String?> sentCookies = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    sentCookies.add(options.headers['cookie'] as String?);
    return ResponseBody.fromString('{}', 200, headers: {
      'set-cookie': ['VISITOR_INFO1_LIVE=marcada; Path=/; Secure'],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('YoutubeSessionRefresher (H-R9-2)', () {
    late DateTime now;
    late int resets;
    late YoutubeSessionRefresher refresher;

    setUp(() {
      now = DateTime(2026, 10, 15, 14);
      resets = 0;
      refresher = YoutubeSessionRefresher(reset: () => resets++, clock: () => now);
    });

    test('el primer "no eres un bot" renueva la sesión para reintentar', () {
      expect(refresher.refreshIfAllowed(), isTrue);
      expect(resets, 1);
    });

    test('si la sesión recién renovada también lo pide, es la red: no se renueva otra vez', () {
      refresher.refreshIfAllowed();
      now = now.add(const Duration(seconds: 20));

      expect(refresher.refreshIfAllowed(), isFalse);
      expect(resets, 1, reason: 'sin bucle de renovaciones mientras la IP siga bloqueada');
    });

    test('pasado el enfriamiento se puede volver a renovar', () {
      refresher.refreshIfAllowed();
      now = now.add(YoutubeSessionRefresher.defaultCooldown + const Duration(seconds: 1));

      expect(refresher.refreshIfAllowed(), isTrue);
      expect(resets, 2);
    });
  });

  test('DartFetchBridge.clearCookies olvida la sesión que guardó YouTube', () async {
    final adapter = _CookieAdapter();
    final bridge = DartFetchBridge(customDio: Dio()..httpClientAdapter = adapter);

    await bridge.fetch(url: 'https://www.youtube.com/sw.js_data');
    await bridge.fetch(url: 'https://www.youtube.com/youtubei/v1/player');
    bridge.clearCookies();
    await bridge.fetch(url: 'https://www.youtube.com/sw.js_data');

    expect(adapter.sentCookies, [null, 'VISITOR_INFO1_LIVE=marcada', null]);
  });
}
