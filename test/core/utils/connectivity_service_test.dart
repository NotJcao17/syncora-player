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
  });
}
