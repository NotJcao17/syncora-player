import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/utils/share_link_builder.dart';

void main() {
  group('ShareLinkBuilder', () {
    test('builds a track deep link', () {
      expect(ShareLinkBuilder.track('123'), 'syncoraplayer://track/123');
    });

    test('builds a playlist deep link', () {
      expect(ShareLinkBuilder.playlist('42'), 'syncoraplayer://playlist/42');
    });

    test('builds an album deep link', () {
      expect(ShareLinkBuilder.album('987'), 'syncoraplayer://album/987');
    });

    // No hay web publicada: una URL https se veria como enlace normal pero
    // fallaria con error de DNS al abrirla.
    test('no genera URLs http(s) mientras no exista la web', () {
      final url = ShareLinkBuilder.playlist('1');
      expect(url.startsWith('syncoraplayer://'), isTrue);
      expect(url.contains('http'), isFalse);
    });
  });
}
