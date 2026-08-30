import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/utils/connectivity_service.dart';

void main() {
  group('DesktopReachabilityTracker', () {
    test('un solo fallo no alcanza para declarar offline', () {
      final tracker = DesktopReachabilityTracker(failureThreshold: 3);
      expect(tracker.recordFailure(), isTrue);
      expect(tracker.recordFailure(), isTrue);
    });

    test('el fallo número N (el umbral) recién ahí declara offline', () {
      final tracker = DesktopReachabilityTracker(failureThreshold: 3);
      expect(tracker.recordFailure(), isTrue);
      expect(tracker.recordFailure(), isTrue);
      expect(tracker.recordFailure(), isFalse);
    });

    test('un solo éxito alcanza para volver a online y resetea la cuenta', () {
      final tracker = DesktopReachabilityTracker(failureThreshold: 3);
      tracker.recordFailure();
      tracker.recordFailure();
      expect(tracker.recordSuccess(), isTrue);
      expect(tracker.consecutiveFailures, 0);

      // Tras el reset, hacen falta de nuevo el umbral completo de fallos.
      expect(tracker.recordFailure(), isTrue);
      expect(tracker.recordFailure(), isTrue);
      expect(tracker.recordFailure(), isFalse);
    });

    test('sigue offline mientras los fallos sigan acumulándose', () {
      final tracker = DesktopReachabilityTracker(failureThreshold: 2);
      expect(tracker.recordFailure(), isTrue);
      expect(tracker.recordFailure(), isFalse);
      expect(tracker.recordFailure(), isFalse);
      expect(tracker.recordFailure(), isFalse);
    });

    test('respeta un umbral de 1: cualquier fallo ya declara offline', () {
      final tracker = DesktopReachabilityTracker(failureThreshold: 1);
      expect(tracker.recordFailure(), isFalse);
    });
    test('un fallo duro (interfaz caída) declara offline sin pasar por el umbral', () {
      final tracker = DesktopReachabilityTracker(failureThreshold: 3);
      expect(tracker.recordHardFailure(), isFalse);
      expect(tracker.consecutiveFailures, 3);

      // Y el siguiente fallo de sonda NO debe revertirlo a online: si la
      // cuenta hubiera quedado en 0, `recordFailure` habría devuelto `true`.
      expect(tracker.recordFailure(), isFalse);
    });
  });

  group('DesktopConnectivityMonitor', () {
    /// Regresión de "la detección se duerme tras unos minutos" (Windows).
    ///
    /// La versión anterior gateaba la sonda periódica con un flag alimentado
    /// solo por `connectivity_plus`. Si ese stream reportaba la interfaz
    /// caída y luego no avisaba que volvió, la sonda quedaba apagada para
    /// siempre y la app no volvía a detectar internet nunca. Sin el arreglo
    /// este test se queda en `false` y falla.
    test(
      'vuelve a online por la sonda aunque connectivity_plus nunca avise que la interfaz volvió',
      () async {
        var reachable = true;
        final interfaceEvents = StreamController<bool>();
        final monitor = DesktopConnectivityMonitor(
          probe: () async => reachable,
          interfaceUpEvents: interfaceEvents.stream,
          probeInterval: const Duration(milliseconds: 20),
        );
        addTearDown(() async {
          await monitor.dispose();
          await interfaceEvents.close();
        });

        final emitted = <bool>[];
        monitor.stream.listen(emitted.add);
        monitor.start(initialInterfaceUp: true);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(emitted, [true]);

        // Se cae la red: la interfaz avisa y la sonda deja de alcanzar.
        reachable = false;
        interfaceEvents.add(false);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(emitted.last, isFalse);

        // Vuelve internet, pero `connectivity_plus` no emite nada.
        reachable = true;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(emitted.last, isTrue);
      },
    );

    test('una sonda que lanza cuenta como fallo, no rompe el stream', () async {
      final interfaceEvents = StreamController<bool>();
      final monitor = DesktopConnectivityMonitor(
        probe: () async => throw const SocketExceptionStub(),
        interfaceUpEvents: interfaceEvents.stream,
        probeInterval: const Duration(milliseconds: 20),
        failureThreshold: 2,
      );
      addTearDown(() async {
        await monitor.dispose();
        await interfaceEvents.close();
      });

      final emitted = <bool>[];
      monitor.stream.listen(emitted.add);
      monitor.start(initialInterfaceUp: true);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(emitted.first, isTrue);
      expect(emitted.last, isFalse);
    });
  });
}

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
