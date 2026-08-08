import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'supabase_album_repository.dart';
import 'supabase_history_repository.dart';
import 'supabase_playlist_repository.dart';

final supabasePlaylistRepositoryProvider = Provider<SupabasePlaylistRepository>((ref) {
  return SupabasePlaylistRepository();
});

final supabaseAlbumRepositoryProvider = Provider<SupabaseAlbumRepository>((ref) {
  return SupabaseAlbumRepository();
});

final supabaseHistoryRepositoryProvider = Provider<SupabaseHistoryRepository>((ref) {
  return SupabaseHistoryRepository();
});
