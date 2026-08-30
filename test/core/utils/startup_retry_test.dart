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

  group('Presupuesto de arranque (Inicio vacio en el arranque en frio)', () {
    /// El fallo de DNS del arranque en Android vuelve en milisegundos, no
    /// espera al `connectTimeout` de Dio. Con el esquema anterior (3 intentos,
    /// esperas de 600 ms y 1200 ms) los tres se agotaban en menos de 2 s, y en
    /// un dispositivo que tarda mas que eso en tener DNS la pantalla de Inicio
    /// quedaba SIEMPRE en "No pudimos cargar el contenido".
    test('aguanta un DNS que tarda varios segundos en estar listo', () async {
      var calls = 0;
      final clock = Stopwatch()..start();

      final result = await retryOnNetworkError(
        () async {
          calls++;
          // La red se vuelve utilizable recien a los 2.5 s de reloj.
          if (clock.elapsed < const Duration(milliseconds: 2500)) {
            throw const SocketException("Failed host lookup: 'api.deezer.com'");
          }
          return 'contenido';
        },
        initialDelay: const Duration(milliseconds: 300),
      );

      expect(result, 'contenido');
      expect(calls, greaterThan(3),
          reason: 'con solo 3 intentos el presupuesto se agotaba antes de los 2 s');
    });

    test('el backoff se acota y no se come el presupuesto en dos esperas', () async {
      var calls = 0;
      final clock = Stopwatch()..start();

      await expectLater(
        retryOnNetworkError(
          () async {
            calls++;
            throw const SocketException('Failed host lookup');
          },
          initialDelay: const Duration(milliseconds: 200),
          maxDelay: const Duration(milliseconds: 400),
          maxElapsed: const Duration(milliseconds: 1500),
          attempts: 100,
        ),
        throwsA(isA<SocketException>()),
      );

      expect(clock.elapsed, lessThan(const Duration(seconds: 3)),
          reason: 'el presupuesto de reloj corta la espera');
      expect(calls, greaterThan(3),
          reason: 'con el tope de espera el presupuesto se reparte en varios intentos');
    });

    test('sin interfaz de red se rinde de inmediato: el aviso offline es instantaneo', () async {
      var calls = 0;
      final clock = Stopwatch()..start();

      await expectLater(
        retryOnNetworkError(
          () async {
            calls++;
            throw const SocketException('Network is unreachable');
          },
          initialDelay: const Duration(seconds: 1),
          shouldRetry: () => false,
        ),
        throwsA(isA<SocketException>()),
      );

      expect(calls, 1);
      expect(clock.elapsed, lessThan(const Duration(milliseconds: 500)),
          reason: 'estando offline de verdad no se quema el presupuesto entero');
    });

    test('con interfaz de red disponible si reintenta', () async {
      var calls = 0;
      final result = await retryOnNetworkError(
        () async {
          calls++;
          if (calls < 3) throw const SocketException('Failed host lookup');
          return 'ok';
        },
        initialDelay: Duration.zero,
        shouldRetry: () => true,
      );
      expect(result, 'ok');
      expect(calls, 3);
    });
  });
}
