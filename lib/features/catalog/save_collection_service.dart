import 'package:drift/drift.dart' show Value;

import '../../data/local_db/daos/playlist_dao.dart';
import '../../data/supabase/supabase_playlist_repository.dart';
import '../player/player_models.dart';

/// Congela una lista de pistas como playlist propia del usuario.
///
/// Es el camino por el que un **mix**, una **playlist editorial de Deezer** o
/// un **Top de país** se convierten en algo suyo. Decisión de diseño acordada
/// antes de implementar: Syncora **no "sigue"** playlists remotas. Guardar es
/// copiar, y la copia ya no cambia nunca sola.
///
/// Motivos, por si alguien lo reconsidera más adelante:
///
/// - Una radio de Deezer (`/radio/{id}/tracks`, `/artist/{id}/radio`) devuelve
///   una selección distinta en cada llamada, así que "seguir" ni siquiera
///   sería posible: no hay nada estable a lo que apuntar.
/// - Nuestro modelo de biblioteca copia pistas a `playlist_tracks`, lo que da
///   gratis el modo offline, la descarga y la edición. Una playlist "seguida"
///   necesitaría un estado no editable propio en toda la UI y reglas nuevas
///   de sincronización.
///
/// Mismo orden de escritura que `createPlaylistWithMatchedTracks` (D-8): local
/// primero, remoto después, y si el remoto falla la playlist se queda
/// local-only sin `remoteId`, que es un estado seguro que ninguna sync poda.
Future<int> saveTracksAsPlaylist({
  required String title,
  String? description,
  required List<SyncoraTrack> tracks,
  required PlaylistDao dao,
  required SupabasePlaylistRepository supabaseRepo,
}) async {
  // Sin `coverUrl` a propósito: la portada por defecto de una playlist es la
  // cuadrícula generada con las 4 primeras portadas distintas (Documento
  // Maestro §1.7), y así la copia se ve como cualquier otra playlist del
  // usuario en vez de heredar la carátula de una fuente que ya no la manda.
  final playlistId = await dao.createPlaylist(title: title, description: description);

  String? remotePlaylistId;
  try {
    final created = await supabaseRepo.createPlaylist(title: title, description: description);
    remotePlaylistId = created['id']?.toString();
  } catch (_) {}

  final remotePayload = <Map<String, dynamic>>[];

  for (final track in tracks) {
    final contributorsJson =
        track.artists.length > 1 ? SyncoraArtistRef.encodeList(track.artists) : null;

    await dao.addTrackToPlaylist(
      playlistId: playlistId,
      trackId: track.deezerId,
      artistId: track.artistId ?? 0,
      albumId: track.albumId ?? 0,
      title: track.title,
      artistName: track.artist,
      albumName: track.album ?? '',
      coverUrl: track.coverUrl,
      durationMs: track.duration?.inMilliseconds ?? 0,
      genre: track.genre,
      contributorsJson: contributorsJson,
    );

    if (remotePlaylistId != null) {
      remotePayload.add({
        'track_id': track.deezerId,
        'artist_id': track.artistId ?? 0,
        'album_id': track.albumId ?? 0,
        'title': track.title,
        'artist_name': track.artist,
        'album_name': track.album ?? '',
        'cover_url': track.coverUrl,
        'duration_ms': track.duration?.inMilliseconds ?? 0,
        'contributors_json': ?contributorsJson,
      });
    }
  }

  if (remotePlaylistId != null && remotePayload.isNotEmpty) {
    try {
      await supabaseRepo.addTracksToPlaylist(remotePlaylistId, remotePayload);
      final local = await dao.getPlaylistById(playlistId);
      if (local != null) {
        await dao.updatePlaylist(local.copyWith(remoteId: Value(remotePlaylistId)));
      }
    } catch (_) {}
  }

  return playlistId;
}
