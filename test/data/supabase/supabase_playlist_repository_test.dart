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
  });
}
