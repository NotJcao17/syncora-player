import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/utils/deezer_image.dart';

void main() {
  group('DeezerImage.atSize', () {
    test('reescribe el tamaño de una URL del CDN de Deezer', () {
      const url =
          'https://e-cdns-images.dzcdn.net/images/cover/abc123/250x250-000000-80-0-0.jpg';
      expect(
        DeezerImage.atSize(url, 1000),
        'https://e-cdns-images.dzcdn.net/images/cover/abc123/1000x1000-000000-80-0-0.jpg',
      );
    });

    test('solo toca el primer segmento de tamaño', () {
      const url = 'https://cdn.test/images/cover/500x500-000000-80-0-0.jpg';
      expect(DeezerImage.atSize(url, 800), 'https://cdn.test/images/cover/800x800-000000-80-0-0.jpg');
    });

    test('deja intacta una URL sin tamaño reconocible', () {
      const url = 'https://example.com/portada.jpg';
      expect(DeezerImage.atSize(url, 1000), url);
    });

    test('tolera cadena vacía', () {
      expect(DeezerImage.atSize('', 1000), '');
    });
  });
}
