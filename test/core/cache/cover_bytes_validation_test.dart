import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/cache/cover_cache_service.dart';

void main() {
  group('CoverCacheService.looksLikeImage (ronda 5)', () {
    test('acepta un JPEG y un PNG de tamaño razonable', () {
      expect(CoverCacheService.looksLikeImage([0xFF, 0xD8, ...List.filled(1000, 0)]), isTrue);
      expect(CoverCacheService.looksLikeImage([0x89, 0x50, 0x4E, 0x47, ...List.filled(1000, 0)]), isTrue);
    });

    test('rechaza respuestas cortadas o que no son imágenes', () {
      expect(CoverCacheService.looksLikeImage(const []), isFalse);
      expect(CoverCacheService.looksLikeImage([0xFF, 0xD8, 0x00]), isFalse);
      expect(CoverCacheService.looksLikeImage('<html>error</html>'.padRight(600).codeUnits), isFalse);
    });
  });
}
