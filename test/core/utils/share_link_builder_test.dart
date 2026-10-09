import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/utils/share_link_builder.dart';

void main() {
  group('ShareLinkBuilder', () {
    // La web (syncora-web) sirve `/playlist/<id>` con la vista de solo lectura.
    test('apunta a la vista de playlist de la web', () {
      expect(
        ShareLinkBuilder.playlist('3f2504e0-4f89-11d3-9a0c-0305e82c3301'),
        'https://syncoraplayer.app/playlist/3f2504e0-4f89-11d3-9a0c-0305e82c3301',
      );
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
