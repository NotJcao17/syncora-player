import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/navigation/shared_playlist_links.dart';
import 'package:syncora_player/core/utils/share_link_builder.dart';

void main() {
  const id = '3f2504e0-4f89-11d3-9a0c-0305e82c3301';

  group('sharedPlaylistIdFromUri', () {
    test('lee el esquema de la app (botón "Abrir en la app" de la web)', () {
      expect(sharedPlaylistIdFromUri(Uri.parse('syncoraplayer://playlist/$id')), id);
    });

    test('lee la dirección de la web', () {
      expect(sharedPlaylistIdFromUri(Uri.parse('https://syncoraplayer.app/playlist/$id')), id);
      expect(sharedPlaylistIdFromUri(Uri.parse('https://www.syncoraplayer.app/playlist/$id/')), id);
    });

    test('normaliza mayúsculas', () {
      expect(sharedPlaylistIdFromUri(Uri.parse('syncoraplayer://playlist/${id.toUpperCase()}')), id);
    });

    test('el enlace que copia la app se puede leer de vuelta', () {
      expect(sharedPlaylistIdFromUri(Uri.parse(ShareLinkBuilder.playlist(id))), id);
    });

    test('ignora el callback de inicio de sesión y enlaces mal formados', () {
      expect(sharedPlaylistIdFromUri(Uri.parse('syncoraplayer://login-callback#access_token=x')), isNull);
      expect(sharedPlaylistIdFromUri(Uri.parse('syncoraplayer://playlist/123')), isNull);
      expect(sharedPlaylistIdFromUri(Uri.parse('syncoraplayer://playlist/')), isNull);
      expect(sharedPlaylistIdFromUri(Uri.parse('https://otro.com/playlist/$id')), isNull);
    });
  });
}
