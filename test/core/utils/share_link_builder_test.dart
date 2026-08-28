import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/utils/share_link_builder.dart';

void main() {
  group('ShareLinkBuilder', () {
    test('builds a well-formed track URL', () {
      expect(ShareLinkBuilder.track('123'), 'https://syncora.app/track/123');
    });

    test('builds a well-formed playlist URL', () {
      expect(ShareLinkBuilder.playlist('42'), 'https://syncora.app/playlist/42');
    });

    test('builds a well-formed album URL', () {
      expect(ShareLinkBuilder.album('987'), 'https://syncora.app/album/987');
    });

    test('never produces a deep-link scheme', () {
      final url = ShareLinkBuilder.playlist('1');
      expect(url.startsWith('https://'), isTrue);
      expect(url.contains('syncoraplayer://'), isFalse);
    });
  });
}
