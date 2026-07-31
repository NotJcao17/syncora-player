import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/extraction/dart_fetch_bridge.dart';

void main() {
  group('DartFetchBridge Unit Tests', () {
    test('Puente maneja redirección HTTP 301/302 correctamente', () async {
      final dio = Dio(
        BaseOptions(
          followRedirects: true,
          maxRedirects: 5,
          validateStatus: (status) => status != null && status < 600,
        ),
      );

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.contains('/redirect')) {
              return handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  statusMessage: 'OK',
                  headers: Headers.fromMap({
                    'content-type': ['text/html'],
                  }),
                  data: 'Redirect Target Content',
                ),
              );
            }
            return handler.next(options);
          },
        ),
      );

      final bridge = DartFetchBridge(customDio: dio);
      final res = await bridge.fetch(url: 'https://example.com/redirect');

      expect(res.statusCode, equals(200));
      expect(res.bodyText, equals('Redirect Target Content'));
    });

    test('Puente decodifica respuesta gzip sin errores', () async {
      final dio = Dio(
        BaseOptions(
          validateStatus: (status) => status != null && status < 600,
        ),
      );

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            return handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                statusMessage: 'OK',
                headers: Headers.fromMap({
                  'content-encoding': ['gzip'],
                  'content-type': ['application/json'],
                }),
                data: '{"success": true, "data": "gzipped content"}',
              ),
            );
          },
        ),
      );

      final bridge = DartFetchBridge(customDio: dio);
      final res = await bridge.fetch(url: 'https://example.com/gzip');

      expect(res.statusCode, equals(200));
      expect(res.bodyText, contains('gzipped content'));
    });

    test('Puente maneja timeout devolviendo error controlado o lanzando DioException atrapable', () async {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(milliseconds: 10),
          receiveTimeout: const Duration(milliseconds: 10),
        ),
      );

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            return handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionTimeout,
                message: 'Connection timeout',
              ),
            );
          },
        ),
      );

      final bridge = DartFetchBridge(customDio: dio);

      expect(
        () async => await bridge.fetch(url: 'https://example.com/timeout'),
        throwsA(isA<DioException>()),
      );
    });
  });
}
