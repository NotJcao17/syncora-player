import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/extraction/models/extraction_result.dart';
import 'package:syncora_player/core/extraction/retry_policy.dart';

void main() {
  group('RetryPolicy Unit Tests (Guard 403)', () {
    late RetryPolicy retryPolicy;

    setUp(() {
      retryPolicy = RetryPolicy();
    });

    test('Primer 403 -> canRetry retorna true', () {
      const videoId = 'test_video_1';
      final result = retryPolicy.canRetry(videoId, ExtractionError.rateLimited);

      expect(result, isTrue);
      expect(retryPolicy.getAttemptCount(videoId), equals(1));
    });

    test('Segundo 403 -> canRetry retorna false (límite alcanzado)', () {
      const videoId = 'test_video_1';
      
      final firstAttempt = retryPolicy.canRetry(videoId, ExtractionError.rateLimited);
      expect(firstAttempt, isTrue);

      final secondAttempt = retryPolicy.canRetry(videoId, ExtractionError.rateLimited);
      expect(secondAttempt, isFalse);
    });

    test('Error lógico (notFound) -> canRetry retorna false de inmediato', () {
      const videoId = 'test_video_2';
      final result = retryPolicy.canRetry(videoId, ExtractionError.notFound);

      expect(result, isFalse);
      expect(retryPolicy.getAttemptCount(videoId), equals(0));
    });

    test('Error de red -> primer intento es true, segundo es false', () {
      const videoId = 'test_video_net';
      expect(retryPolicy.canRetry(videoId, ExtractionError.networkError), isTrue);
      expect(retryPolicy.canRetry(videoId, ExtractionError.networkError), isFalse);
    });

    test('reset() reinicia el contador de intentos a 0', () {
      const videoId = 'test_video_reset';

      retryPolicy.canRetry(videoId, ExtractionError.rateLimited);
      expect(retryPolicy.getAttemptCount(videoId), equals(1));

      retryPolicy.reset(videoId);
      expect(retryPolicy.getAttemptCount(videoId), equals(0));

      expect(retryPolicy.canRetry(videoId, ExtractionError.rateLimited), isTrue);
    });
  });
}
