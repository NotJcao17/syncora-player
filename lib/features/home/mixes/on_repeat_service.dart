import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/startup_retry.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../player/player_models.dart';
import 'mix_engine.dart';
import 'mix_providers.dart';

/// Prefijo del `sourceRef` de la playlist generada "On Repeat".
/// El periodo que generó su contenido se pega detrás: `mix:on_repeat:2026-W38`.
const String onRepeatSourcePrefix = 'mix:on_repeat';

const String onRepeatTitle = 'On Repeat';

/// "On Repeat" es una **playlist real y permanente**, no un mix efímero.
///
/// Decisión tomada tras las pruebas en dispositivo: como snapshot no
/// funcionaba — al reiniciar la app se generaba otro y había que volver a
/// guardarlo, acumulando copias fechadas en la biblioteca. Es el mismo modelo
/// que usa Spotify para sus playlists de sistema, y el mismo que "Tus me
/// gusta" en Syncora: existe siempre, aparece en Biblioteca, **se regenera
/// sola en el sitio** y no se edita a mano.
///
/// Solo vive en local (`remoteId` nulo, nunca se sube): sale del historial de
/// escucha de este dispositivo, así que cada uno tiene el suyo. `SyncService`
/// no la toca — solo poda playlists que sí tienen `remoteId`.
///
/// Cadencia semanal: se regenera cuando cambia [MixEngine.weekKey], no en cada
/// arranque. Si en un momento dado no hay historial suficiente, la playlist
/// existente **se deja como está** en vez de vaciarla: quedarse con la de la
/// semana pasada es mejor que quedarse sin nada.
final onRepeatPlaylistProvider = FutureProvider<Playlist?>((ref) async {
  final dao = ref.watch(playlistDaoProvider);
  final historyDao = ref.watch(listeningHistoryDaoProvider);
  final resolver = ref.watch(trackResolverProvider);

  final existing = await dao.getGeneratedPlaylist(onRepeatSourcePrefix);

  final now = DateTime.now();
  final periodRef = '$onRepeatSourcePrefix:${MixEngine.weekKey(now)}';

  // Ya está al día: ni se recalcula ni se toca la base.
  if (existing != null && existing.sourceRef == periodRef) return existing;

  final entries = await historyDao.getRecentHistory(limit: 500);
  final trackIds = MixEngine.rankOnRepeatTrackIds(entries, now: now, limit: 30);
  if (trackIds.length < onRepeatMinTracks) return existing;

  // No es urgente: que el primer frame y una reproducción inmediata ganen la
  // carrera por el hilo principal y por la red.
  await settleAfterFirstPaint();

  final tracks = await resolver.resolve(trackIds);
  if (tracks.length < onRepeatMinTracks) return existing;

  final playlistId = existing?.id ??
      await dao.createPlaylist(
        title: onRepeatTitle,
        description: 'Lo que más repetiste este mes. Se actualiza sola cada semana.',
        sourceRef: periodRef,
        isGenerated: true,
      );

  await dao.replaceTracks(playlistId, tracks.map(_toCompanion).toList());

  if (existing != null) {
    await dao.updatePlaylist(existing.copyWith(sourceRef: Value(periodRef)));
  }

  return dao.getPlaylistById(playlistId);
});

/// Mínimo de pistas para que "On Repeat" tenga sentido como playlist.
const int onRepeatMinTracks = 8;

PlaylistTracksCompanion _toCompanion(SyncoraTrack track) => PlaylistTracksCompanion.insert(
      // `playlistId` y `orderIndex` los rellena `replaceTracks`.
      playlistId: 0,
      trackId: track.deezerId,
      artistId: track.artistId ?? 0,
      albumId: track.albumId ?? 0,
      title: track.title,
      artistName: track.artist,
      albumName: track.album ?? '',
      coverUrl: track.coverUrl,
      durationMs: track.duration?.inMilliseconds ?? 0,
      genre: Value(track.genre),
      contributorsJson:
          Value(track.artists.length > 1 ? SyncoraArtistRef.encodeList(track.artists) : null),
    );
