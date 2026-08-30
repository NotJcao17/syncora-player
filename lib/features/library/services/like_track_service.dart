import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/contributor_resolver.dart';
import '../../../data/apis/deezer_api.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/local_db/daos/playlist_dao.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/supabase/supabase_playlist_repository.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../player/player_models.dart';

/// Resultado de alternar el "me gusta" de una pista.
class LikeToggleResult {
  /// Estado final: `true` si quedó marcada como favorita.
  final bool isLiked;

  /// `true` si la playlist remota existía pero la operación contra Supabase
  /// falló (normalmente porque ya no existe en la nube).
  final bool remoteFailed;

  const LikeToggleResult({required this.isLiked, this.remoteFailed = false});
}

/// Alterna "Tus me gusta" para [track], en local **y** en Supabase.
///
/// Existía una única implementación completa dentro del menú de 3 puntos de
/// `TrackTile`, mientras que los corazones del mini reproductor y del
/// reproductor a pantalla completa solo escribían en Drift. El resultado era
/// que dar "me gusta" a la canción que estaba sonando parecía funcionar, pero
/// al recargar la playlist la sincronización con la nube podaba esa pista —
/// nunca había llegado al servidor. Además esos dos caminos mandaban
/// `artistId`/`albumId` en 0 y sin género, ensuciando los datos guardados.
///
/// Centralizarlo evita que los tres vuelvan a divergir.
Future<LikeToggleResult> toggleTrackLike(WidgetRef ref, SyncoraTrack track) {
  return toggleTrackLikeWith(
    dao: ref.read(playlistDaoProvider),
    supabaseRepo: ref.read(supabasePlaylistRepositoryProvider),
    deezerApi: ref.read(deezerApiProvider),
    track: track,
  );
}

/// Igual que [toggleTrackLike] pero con las dependencias explícitas, para los
/// adaptadores del sistema operativo (barra de tareas de Windows, notificación
/// y pantalla de bloqueo de Android), que no son widgets y no tienen `WidgetRef`.
/// Sin esto esos corazones escribían solo en Drift y el cambio se revertía en
/// el siguiente sync.
Future<LikeToggleResult> toggleTrackLikeWith({
  required PlaylistDao dao,
  required SupabasePlaylistRepository supabaseRepo,
  required DeezerApi deezerApi,
  required SyncoraTrack track,
}) async {
  final trackIdInt = int.tryParse(track.id) ?? track.id.hashCode.abs();
  final contributors = await resolveTrackContributors(deezerApi, track);

  final isLiked = await dao.toggleLikeTrack(
    trackId: trackIdInt,
    artistId: track.artistId ?? 0,
    albumId: track.albumId ?? 0,
    title: track.title,
    artistName: track.artist,
    albumName: track.album ?? '',
    coverUrl: track.coverUrl,
    durationMs: (track.duration ?? Duration.zero).inMilliseconds,
    contributorsJson: SyncoraArtistRef.encodeList(contributors),
  );

  final likedPlaylist = await dao.getLikedPlaylist();
  final wasLocalOnly = likedPlaylist.remoteId == null;
  var likedRemoteId = likedPlaylist.remoteId;

  if (likedRemoteId == null) {
    try {
      final res = await supabaseRepo.getOrCreateLikedPlaylist();
      likedRemoteId = res['id']?.toString();
    } catch (_) {}
  }

  // La playlist de "me gusta" podía existir solo en local (modo sin cuenta, o
  // creada antes de iniciar sesión): al enlazarla por primera vez hay que subir
  // lo que ya tenía, o esas pistas se perderían en el próximo sync.
  var backfillOk = true;
  if (wasLocalOnly && likedRemoteId != null) {
    try {
      final existingTracks = await dao.getTracksOrdered(likedPlaylist.id);
      if (existingTracks.isNotEmpty) {
        await supabaseRepo.addTracksToPlaylist(
          likedRemoteId,
          existingTracks
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
      backfillOk = false;
    }
  }

  var remoteFailed = false;
  if (likedRemoteId != null) {
    if (!wasLocalOnly) {
      try {
        if (isLiked) {
          await supabaseRepo.addTrackToPlaylist(likedRemoteId, {
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
        } else {
          await supabaseRepo.removeTrackFromPlaylist(likedRemoteId, trackIdInt);
        }
      } catch (_) {
        remoteFailed = true;
      }
    }

    if (wasLocalOnly && backfillOk) {
      try {
        await dao.updatePlaylist(likedPlaylist.copyWith(remoteId: Value(likedRemoteId)));
      } catch (_) {}
    }
  }

  return LikeToggleResult(isLiked: isLiked, remoteFailed: remoteFailed);
}
