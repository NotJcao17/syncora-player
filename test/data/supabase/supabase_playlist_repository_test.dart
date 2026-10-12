import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/supabase/supabase_playlist_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SupabasePlaylistRepository Tests', () {
    late SupabasePlaylistRepository repository;

    setUp(() {
      repository = SupabasePlaylistRepository();
    });

    test('fetchUserPlaylists returns empty list when unauthenticated/test env', () async {
      final playlists = await repository.fetchUserPlaylists();
      expect(playlists, isEmpty);
    });

    test('createPlaylist returns empty map in test env when unauthenticated', () async {
      final result = await repository.createPlaylist(title: 'Test Playlist');
      expect(result, isA<Map<String, dynamic>>());
    });

    test('getOrCreateLikedPlaylist returns empty map in test env when unauthenticated', () async {
      final result = await repository.getOrCreateLikedPlaylist();
      expect(result, isA<Map<String, dynamic>>());
    });

    test('updatePlaylist does not crash in test env', () async {
      expect(
        () async => await repository.updatePlaylist('test-id', title: 'New Title'),
        returnsNormally,
      );
    });

    test('deletePlaylist does not crash in test env', () async {
      expect(
        () async => await repository.deletePlaylist('test-id'),
        returnsNormally,
      );
    });
  
  test('H-R8-12: las canciones sin order_index van detrás de la última de la playlist', () {
    final rows = SupabasePlaylistRepository.assignAppendOrder([
      {'track_id': 1},
      {'track_id': 2, 'order_index': 7},
      {'track_id': 3},
    ], 41);
    expect(rows.map((r) => r['order_index']), [42, 7, 43]);
    expect(SupabasePlaylistRepository.assignAppendOrder([{'track_id': 1}], -1).single['order_index'], 0);
  });
});
}
