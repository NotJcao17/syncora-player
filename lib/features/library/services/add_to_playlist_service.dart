import 'package:drift/drift.dart';

import '../../../core/limits/app_limits.dart';
import '../../../data/local_db/daos/playlist_dao.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../../data/supabase/supabase_playlist_repository.dart';
import '../../player/player_models.dart';

/// Qué pasó al agregar una canción a una playlist.
enum AddToPlaylistOutcome {
  added,

  /// Llegó al límite de canciones (local o rechazado por el servidor).
  full,

  /// La nube rechazó la canción por otra razón: la playlist ya no existe
  /// allí. La copia local se borra (salvo "Tus me gusta"), como siempre.
  remoteGone,
}

/// Agrega [track] a [playlist], primero en la nube y después en local
/// (Pitfall #28: si solo se escribiera en Drift, el sync lo borraría).
///
/// Es el camino de "Agregar a playlist" de una canción; antes vivía dentro
/// del diálogo de `TrackContextMenu`. Si la playlist nunca se subió (creada
/// sin red), se sube con sus canciones antes de agregar la nueva.
Future<AddToPlaylistOutcome> addTrackToPlaylistSynced({
  required PlaylistDao dao,
  required SupabasePlaylistRepository repo,
  required Playlist playlist,
  required SyncoraTrack track,
  required List<SyncoraArtistRef> contributors,
}) async {
  final pl = playlist;
  if (AppLimits.roomFor(await dao.countTracks(pl.id)) <= 0) return AddToPlaylistOutcome.full;

  final trackIdInt = int.tryParse(track.id) ?? track.id.hashCode.abs();
  var remoteId = pl.remoteId;
  final wasLocalOnly = remoteId == null;
  if (remoteId == null) {
    try {
      final created = pl.isLiked
          ? await repo.getOrCreateLikedPlaylist()
          : await repo.createPlaylist(
              title: pl.title,
              description: pl.description,
              isPublic: pl.isPublic,
              isLiked: pl.isLiked,
            );
      remoteId = created['id']?.toString();
    } catch (_) {}
  }

  var existingTracksUploadOk = true;
  if (wasLocalOnly && remoteId != null) {
    try {
      final currentTracks = await dao.getTracksOrdered(pl.id);
      if (currentTracks.isNotEmpty) {
        await repo.addTracksToPlaylist(
          remoteId,
          currentTracks
              .map((t) => {
                    'track_id': t.trackId,
                    'artist_id': t.artistId,
                    'album_id': t.albumId,
                    'title': t.title,
                    'artist_name': t.artistName,
                    'album_name': t.albumName,
                    'cover_url': t.coverUrl,
                    'duration_ms': t.durationMs,
                    if (t.genre != null) 'genre': t.genre,
                    if (t.contributorsJson != null) 'contributors_json': t.contributorsJson,
                  })
              .toList(),
        );
      }
    } catch (_) {
      existingTracksUploadOk = false;
    }
  }

  if (remoteId != null) {
    try {
      await repo.addTrackToPlaylist(remoteId, {
        'track_id': trackIdInt,
        'artist_id': track.artistId ?? 0,
        'album_id': track.albumId ?? 0,
        'title': track.title,
        'artist_name': track.artist,
        'album_name': track.album ?? '',
        'cover_url': track.coverUrl,
        'duration_ms': (track.duration ?? Duration.zero).inMilliseconds,
        'genre': track.genre,
        if (contributors.isNotEmpty) 'contributors_json': SyncoraArtistRef.encodeList(contributors),
      });
    } catch (e) {
      // El servidor rechazó por el límite de canciones: la playlist existe,
      // no hay que tratarla como borrada en la nube.
      if (AppLimits.isTrackLimitError(e)) return AddToPlaylistOutcome.full;
      if (!pl.isLiked) await dao.deletePlaylist(pl.id);
      return AddToPlaylistOutcome.remoteGone;
    }

    if (wasLocalOnly && existingTracksUploadOk) {
      try {
        await dao.updatePlaylist(pl.copyWith(remoteId: Value(remoteId)));
      } catch (_) {}
    }
  }

  await dao.addTrackToPlaylist(
    playlistId: pl.id,
    trackId: trackIdInt,
    artistId: track.artistId ?? 0,
    albumId: track.albumId ?? 0,
    title: track.title,
    artistName: track.artist,
    albumName: track.album ?? '',
    coverUrl: track.coverUrl,
    durationMs: (track.duration ?? Duration.zero).inMilliseconds,
    genre: track.genre,
    contributorsJson: SyncoraArtistRef.encodeList(contributors),
  );
  return AddToPlaylistOutcome.added;
}

/// Resultado de agregar una canción a varias playlists.
class AddToPlaylistsResult {
  AddToPlaylistsResult();

  final List<Playlist> added = [];
  final List<Playlist> full = [];
  final List<Playlist> gone = [];

  /// Texto del aviso final.
  String get message {
    final parts = <String>[];
    if (added.length == 1) {
      parts.add('Agregada a "${added.single.title}"');
    } else if (added.length > 1) {
      parts.add('Agregada a ${added.length} playlists');
    }
    if (full.isNotEmpty) {
      if (full.length == 1 && added.isEmpty) {
        parts.add(AppLimits.playlistFullMessage);
      } else {
        parts.add(full.length == 1 ? '"${full.single.title}" está llena' : '${full.length} playlists están llenas');
      }
    }
    if (gone.isNotEmpty) {
      parts.add(gone.length == 1
          ? '"${gone.single.title}" ya no existe en la nube'
          : '${gone.length} playlists ya no existen en la nube');
    }
    return parts.join('. ');
  }
}

/// Agrega [track] a cada una de [playlists], una tras otra. Una que falle no
/// detiene a las demás.
Future<AddToPlaylistsResult> addTrackToPlaylistsSynced({
  required PlaylistDao dao,
  required SupabasePlaylistRepository repo,
  required List<Playlist> playlists,
  required SyncoraTrack track,
  required List<SyncoraArtistRef> contributors,
}) async {
  final result = AddToPlaylistsResult();
  for (final pl in playlists) {
    final outcome = await addTrackToPlaylistSynced(
      dao: dao,
      repo: repo,
      playlist: pl,
      track: track,
      contributors: contributors,
    );
    switch (outcome) {
      case AddToPlaylistOutcome.added:
        result.added.add(pl);
      case AddToPlaylistOutcome.full:
        result.full.add(pl);
      case AddToPlaylistOutcome.remoteGone:
        result.gone.add(pl);
    }
  }
  return result;
}
