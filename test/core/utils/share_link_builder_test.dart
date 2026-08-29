import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/utils/share_link_builder.dart';

void main() {
  group('ShareLinkBuilder', () {
    test('builds a track URL', () {
      expect(ShareLinkBuilder.track('123'), 'https://syncora.netlify.app/track/123');
    });

    test('builds a playlist URL', () {
      expect(ShareLinkBuilder.playlist('42'), 'https://syncora.netlify.app/playlist/42');
    });

    test('builds an album URL', () {
      expect(ShareLinkBuilder.album('987'), 'https://syncora.netlify.app/album/987');
    });

    // Un esquema propio no lo convierten en enlace WhatsApp/notas/correo: llega
    // como texto plano y no se puede tocar.
    test('usa https para que el enlace sea clicable al pegarlo', () {
      final url = ShareLinkBuilder.playlist('1');
      expect(url.startsWith('https://'), isTrue);
      expect(url.contains('syncoraplayer://'), isFalse);
    });
  });
}
