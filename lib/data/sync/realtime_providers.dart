import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/auth_provider.dart';
import '../local_db/database_provider.dart';
import '../supabase/supabase_providers.dart';
import 'realtime_sync_service.dart';

final realtimeSyncServiceProvider = Provider<RealtimeSyncService>((ref) {
  final service = RealtimeSyncService(
    playlistRepo: ref.watch(supabasePlaylistRepositoryProvider),
    albumRepo: ref.watch(supabaseAlbumRepositoryProvider),
    playlistDao: ref.watch(playlistDaoProvider),
    savedAlbumDao: ref.watch(savedAlbumDaoProvider),
    ref: ref,
  );

  final user = ref.watch(currentUserProvider);

  if (user != null) {
    service.subscribe(user.id);
  } else {
    service.unsubscribe();
  }

  ref.onDispose(() {
    service.unsubscribe();
  });

  return service;
});
