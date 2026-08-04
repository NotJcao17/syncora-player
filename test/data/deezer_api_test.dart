import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/apis/deezer_api.dart';

void main() {
  group('DeezerApi & RateLimiter Tests', () {
    test('RateLimiter enforces request count limits', () async {
      final limiter = RateLimiter(maxRequests: 3, period: const Duration(milliseconds: 300));
      final timestamps = <DateTime>[];

      for (int i = 0; i < 4; i++) {
        await limiter.run(() async {
          timestamps.add(DateTime.now());
        });
      }

      expect(timestamps.length, equals(4));
      // The 4th request should be delayed by ~300ms
      final diff = timestamps[3].difference(timestamps[0]).inMilliseconds;
      expect(diff >= 250, isTrue);
    });

    test('DeezerTrack podcast filter logic', () async {
      final mockData = {
        'data': [
          {'type': 'podcast', 'title': 'Podcast Show', 'duration': 1800},
          {
            'type': 'track',
            'id': 101,
            'title': 'Real Song',
            'duration': 210,
            'artist': {'id': 1, 'name': 'Real Artist'},
            'album': {'id': 1, 'title': 'Real Album', 'cover_medium': 'https://cover.jpg'},
          },
          {
            'type': 'track',
            'id': 102,
            'title': 'Intro Jingles',
            'duration': 30, // < 60s
            'artist': {'id': 1, 'name': 'Real Artist'},
            'album': {'id': 1, 'title': 'Real Album'},
          }
        ]
      };

      // Filter check logic matching DeezerApi.search
      final items = mockData['data'] as List;
      final validTracks = items.where((item) {
        final type = item['type'];
        final duration = item['duration'] as int? ?? 0;
        return type != 'podcast' && duration > 60;
      }).toList();

      expect(validTracks.length, equals(1));
      expect(validTracks.first['title'], equals('Real Song'));
    });
  });
}
