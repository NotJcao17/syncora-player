import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../local_db/database_provider.dart';
import '../supabase/supabase_providers.dart';
import 'realtime_sync_service.dart';

final realtimeSyncServiceProvider = Provider<RealtimeSyncService>((ref) {
  return RealtimeSyncService(
    playlistRepo: ref.watch(supabasePlaylistRepositoryProvider),
    albumRepo: ref.watch(supabaseAlbumRepositoryProvider),
    playlistDao: ref.watch(playlistDaoProvider),
    savedAlbumDao: ref.watch(savedAlbumDaoProvider),
    ref: ref,
  );
});
