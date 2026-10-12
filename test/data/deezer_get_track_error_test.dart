import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/apis/deezer_api.dart';

/// Deezer responde 200 con `{"error": ...}` cuando falla.
class _ErrorAdapter implements HttpClientAdapter {
  int requests = 0;
  Map<String, dynamic> body = const {
    'error': {'type': 'Exception', 'message': 'Quota limit exceeded', 'code': 4},
  };

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests++;
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('H-R8-10: una respuesta de error de Deezer no se convierte en una pista "Desconocida" ni se cachea', () async {
    final adapter = _ErrorAdapter();
    final api = DeezerApi(dio: Dio(BaseOptions(baseUrl: 'https://api.deezer.com'))..httpClientAdapter = adapter);

    await expectLater(api.getTrack(42), throwsA(isA<StateError>()));
    await expectLater(api.getTrack(42), throwsA(isA<StateError>()));
    expect(adapter.requests, 2, reason: 'el error no queda en caché');

    adapter.body = const {'error': {'type': 'DataException', 'message': 'no data', 'code': 800}};
    await expectLater(api.getTrack(43), throwsA(isA<DeezerNotFoundException>()));
  });
}
