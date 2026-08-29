import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/utils/startup_retry.dart';

void main() {
  group('isTransientNetworkError', () {
    test('reconoce el fallo de DNS del arranque en frío', () {
      // El error exacto que aparece en los logs del arranque en Android.
      expect(
        isTransientNetworkError(
          const SocketException("Failed host lookup: 'www.youtube.com'"),
        ),
        isTrue,
      );
    });

    test('reconoce el error envuelto por Dio (pierde el tipo original)', () {
      expect(
        isTransientNetworkError(
          'DioException [connection error]: The connection errored: '
          "Failed host lookup: 'api.deezer.com'",
        ),
        isTrue,
      );
    });

    test('NO reconoce errores de la respuesta, que no mejoran al reintentar', () {
      expect(isTransientNetworkError(FormatException('json inválido')), isFalse);
      expect(isTransientNetworkError('404 Not Found'), isFalse);
    });
  });

  group('retryOnNetworkError', () {
    test('reintenta un fallo de red y devuelve el resultado del segundo intento', () async {
      var calls = 0;
      final result = await retryOnNetworkError(
        () async {
          calls++;
          if (calls == 1) throw const SocketException('Failed host lookup');
          return 'ok';
        },
        initialDelay: Duration.zero,
      );
      expect(result, 'ok');
      expect(calls, 2);
    });

    test('no reintenta un error que no es de red', () async {
      var calls = 0;
      await expectLater(
        retryOnNetworkError(
          () async {
            calls++;
            throw FormatException('json inválido');
          },
          initialDelay: Duration.zero,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(calls, 1, reason: 'repetir un error de parseo no lo arregla');
    });

    test('se rinde tras agotar los intentos y relanza el último error', () async {
      var calls = 0;
      await expectLater(
        retryOnNetworkError(
          () async {
            calls++;
            throw const SocketException('Failed host lookup');
          },
          attempts: 3,
          initialDelay: Duration.zero,
        ),
        throwsA(isA<SocketException>()),
      );
      expect(calls, 3);
    });

    test('no reintenta cuando el primer intento funciona', () async {
      var calls = 0;
      final result = await retryOnNetworkError(() async {
        calls++;
        return 42;
      });
      expect(result, 42);
      expect(calls, 1);
    });
  });
}
