import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../../data/supabase/supabase_providers.dart';

/// Fija o desfija [playlist] (ronda 4).
///
/// Escribe primero en Supabase y solo después en Drift (Pitfall #28): si la
/// nube no acepta el cambio, el siguiente sync lo revertiría, así que no se
/// finge un éxito local. "On Repeat" nunca sube a la nube (se deriva del
/// historial del dispositivo), así que para ella el cambio es solo local.
///
/// Devuelve `false` si la escritura remota falló.
Future<bool> togglePlaylistPin(WidgetRef ref, Playlist playlist) async {
  final pinned = !playlist.isPinned;
  final remoteId = playlist.remoteId;
  if (remoteId != null && !playlist.isGenerated) {
    try {
      await ref.read(supabasePlaylistRepositoryProvider).updatePlaylist(remoteId, isPinned: pinned);
    } catch (_) {
      return false;
    }
  }
  await ref.read(playlistDaoProvider).updatePlaylist(playlist.copyWith(isPinned: pinned));
  return true;
}
