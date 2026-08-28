import 'dart:async';
import 'package:csv/csv.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../../../core/utils/contributor_resolver.dart';
import '../../../data/apis/deezer_api.dart';
import '../../../data/local_db/daos/listening_history_dao.dart';
import '../../../data/local_db/daos/playlist_dao.dart';
import '../../../data/local_db/daos/saved_album_dao.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../../data/models/deezer/deezer_track.dart';
import '../../../data/supabase/supabase_album_repository.dart';
import '../../../data/supabase/supabase_history_repository.dart';
import '../../../data/supabase/supabase_playlist_repository.dart';
import '../../player/player_models.dart';
import '../../search/exact_track_search.dart';

class RawImportTrack {
  final String title;
  final String artist;
  final String? album;
  final String? isrc;
  final int? durationMs;

  const RawImportTrack({
    required this.title,
    required this.artist,
    this.album,
    this.isrc,
    this.durationMs,
  });

  @override
  String toString() => artist.isEmpty ? title : '$artist - $title';
}

class ImportProgress {
  final int current;
  final int total;
  final String currentTrackName;

  const ImportProgress({
    required this.current,
    required this.total,
    required this.currentTrackName,
  });

  double get ratio => total == 0 ? 0 : current / total;
}

class ImportResult {
  final List<DeezerTrack> matchedTracks;
  final List<RawImportTrack> unmatchedTracks;

  const ImportResult({
    required this.matchedTracks,
    required this.unmatchedTracks,
  });

  int get total => matchedTracks.length + unmatchedTracks.length;
}

class PlaylistImportExportService {
  final DeezerApi _deezerApi;

  PlaylistImportExportService(this._deezerApi);

  /// Fase 7.F.3 -- parseo de `result['tracks']` (o `result['songs']` para
  /// `lyric_search`) compartido entre las 4 hojas de IA que reciben ese
  /// mismo shape `{title, artist}` de la Edge Function (7.F.1, 7.F.2, 7.F.3
  /// modo agregar, 7.F.4) -- antes de esta extracción cada una tenía su
  /// propia copia del mismo bucle.
  static List<RawImportTrack> parseTrackSuggestions(dynamic tracksRaw) {
    final result = <RawImportTrack>[];
    if (tracksRaw is List) {
      for (final entry in tracksRaw) {
        if (entry is Map) {
          final title = (entry['title'] as String?)?.trim() ?? '';
          final artist = (entry['artist'] as String?)?.trim() ?? '';
          if (title.isNotEmpty) {
            result.add(RawImportTrack(title: title, artist: artist));
          }
        }
      }
    }
    return result;
  }

  /// D-5: recorta al número exacto pedido tras matchear contra Deezer, sin
  /// fallar si vino corto -- compartido entre 7.F.1, 7.F.2 y 7.F.3 (modo
  /// agregar).
  static List<DeezerTrack> trimToCount(List<DeezerTrack> tracks, int? exact) {
    if (exact == null || tracks.length <= exact) return tracks;
    return tracks.sublist(0, exact);
  }

  /// Parse CSV or TXT file contents into a list of RawImportTrack objects
  List<RawImportTrack> parseFileContent(String fileContent) {
    final List<RawImportTrack> results = [];
    final lines = fileContent.split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return results;

    // Check if it's CSV
    if (fileContent.contains(',') || fileContent.contains('\t')) {
      try {
        final rows = csv.decode(fileContent.replaceAll('\r\n', '\n'));

        if (rows.isNotEmpty) {
          // Check header row. Detección flexible (B1): distintos exportadores
          // (Spotify, TuneMyMusic, etc.) usan nombres de columna distintos para
          // lo mismo — ej. Spotify exporta "Artist Name(s)", que no matcheaba
          // ninguno de los nombres exactos que reconocíamos antes, así que toda
          // fila se importaba sin artista. `contains` en vez de igualdad exacta
          // para artist/album/duration cubre esas variantes sin falsos positivos
          // entre sí (cada columna solo puede caer en una categoría).
          final firstRowStr = rows.first.map((e) => e.toString().toLowerCase().trim()).toList();
          int titleIdx = -1;
          int artistIdx = -1;
          int albumIdx = -1;
          int isrcIdx = -1;
          int durationIdx = -1;

          for (int i = 0; i < firstRowStr.length; i++) {
            final col = firstRowStr[i];
            if (titleIdx == -1 && (col == 'name' || col == 'title' || col == 'track name' || col == 'song')) {
              titleIdx = i;
            } else if (artistIdx == -1 && col.contains('artist')) {
              artistIdx = i;
            } else if (albumIdx == -1 && col.contains('album')) {
              albumIdx = i;
            } else if (isrcIdx == -1 && col == 'isrc') {
              isrcIdx = i;
            } else if (durationIdx == -1 && col.contains('duration')) {
              durationIdx = i;
            }
          }

          int startRow = 0;
          if (titleIdx != -1 || artistIdx != -1) {
            // Header detected
            startRow = 1;
          } else {
            // Default column assumptions: col 0 = title or artist, col 1 = artist or title
            titleIdx = 0;
            artistIdx = 1;
            if (firstRowStr.length > 2) albumIdx = 2;
          }

          for (int i = startRow; i < rows.length; i++) {
            final row = rows[i];
            if (row.isEmpty) continue;

            final titleStr = (titleIdx >= 0 && titleIdx < row.length) ? row[titleIdx].toString().trim() : '';
            final artistStr = (artistIdx >= 0 && artistIdx < row.length) ? row[artistIdx].toString().trim() : '';
            final albumStr = (albumIdx >= 0 && albumIdx < row.length) ? row[albumIdx].toString().trim() : null;
            final isrcStr = (isrcIdx >= 0 && isrcIdx < row.length) ? row[isrcIdx].toString().trim() : null;
            final durationStr =
                (durationIdx >= 0 && durationIdx < row.length) ? row[durationIdx].toString().trim() : '';
            final durationMs = int.tryParse(durationStr);

            if (titleStr.isNotEmpty || artistStr.isNotEmpty) {
              results.add(RawImportTrack(
                title: titleStr.isEmpty ? 'Desconocida' : titleStr,
                artist: artistStr,
                album: albumStr,
                isrc: isrcStr,
                durationMs: durationMs,
              ));
            }
          }

          if (results.isNotEmpty) return results;
        }
      } catch (e) {
        if (kDebugMode) print('CSV parsing failed, falling back to line parsing: $e');
      }
    }

    // Fallback: Plain text line parsing ("Artist - Title" or "Title")
    for (final line in lines) {
      final cleanLine = line.trim();
      if (cleanLine.isEmpty) continue;

      if (cleanLine.contains(' - ')) {
        final parts = cleanLine.split(' - ');
        final artist = parts[0].trim();
        final title = parts.sublist(1).join(' - ').trim();
        results.add(RawImportTrack(title: title, artist: artist));
      } else {
        results.add(RawImportTrack(title: cleanLine, artist: ''));
      }
    }

    return results;
  }

  /// B2: cadena de fallback (decisión 5 del plan) — sintaxis avanzada precisa
  /// pero frágil ante typos/variantes de escritura, luego texto plano, luego
  /// solo título como último recurso (`ExactTrackSearch.cascadeSearch`,
  /// módulo compartido con D3 desde Fase D). Cada tier valida por duración
  /// (B3) antes de aceptar, salvo el último, donde no hay mejor alternativa.
  Future<DeezerTrack?> _resolveTrack(RawImportTrack item) async {
    final tracks = await ExactTrackSearch.cascadeSearch(
      _deezerApi,
      artist: item.artist,
      title: item.title,
      accept: (list) => ExactTrackSearch.bestByDuration(list, item.durationMs, toleranceSec: 20) != null,
    );
    if (tracks.isEmpty) return null;
    return ExactTrackSearch.bestByDuration(tracks, item.durationMs, toleranceSec: 1 << 30) ?? tracks.first;
  }

  /// Process raw tracks sequentially against Deezer API with rate limiting
  Stream<ImportProgress> processImport({
    required List<RawImportTrack> rawTracks,
    required List<DeezerTrack> outMatched,
    required List<RawImportTrack> outUnmatched,
  }) async* {
    for (int i = 0; i < rawTracks.length; i++) {
      final item = rawTracks[i];
      yield ImportProgress(
        current: i + 1,
        total: rawTracks.length,
        currentTrackName: item.toString(),
      );

      try {
        final match = await _resolveTrack(item);
        if (match != null) {
          outMatched.add(match);
        } else {
          outUnmatched.add(item);
        }
      } catch (e) {
        outUnmatched.add(item);
      }

      // Pitfall #4 & #22: 200ms pause between sequential requests
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  /// D-8 / Fase 7.F.1, punto 3 -- secuencia canónica de inserción de una
  /// playlist ya resuelta contra Deezer (título/descripción + pistas ya
  /// matcheadas), compartida por **ambos** flujos que crean una playlist a
  /// partir de sugerencias externas: la importación CSV/TXT
  /// (`library_screen.dart#_importPlaylistFromFile`) y "Crear playlist con
  /// IA" (7.F.1). Antes de esta extracción cada flujo tenía su propia copia
  /// de este código -- ahora es literalmente el mismo, evitando que diverjan.
  ///
  /// Orden estricto (NO reordenar, ver el comentario largo que originalmente
  /// vivía en `library_screen.dart` explicando la condición de carrera real
  /// que motivó este orden):
  ///   1. Crear la playlist local (`dao.createPlaylist`).
  ///   2. Crear la contraparte remota (`supabaseRepo.createPlaylist`) --
  ///      **sin** escribir todavía `remoteId` en la playlist local.
  ///   3. Por cada pista matcheada: resolver colaboradores
  ///      (`resolveDeezerTrackContributors`), insertarla en local
  ///      (`dao.addTrackToPlaylist`) y acumular su payload remoto.
  ///   4. Subir el lote remoto de una sola vez (`supabaseRepo.addTracksToPlaylist`).
  ///   5. Recién ahora, con local y remoto ya iguales, marcar `remoteId` en
  ///      la playlist local -- es la señal que habilita la sincronización
  ///      automática al abrirla (`playlist_detail_screen.dart`). Si se
  ///      escribiera antes (ej. justo tras el paso 2), una sync disparada
  ///      mientras las pistas todavía se suben vería un remoto a medio
  ///      llenar y podaría lo local que aún no llegó a subirse -- bug real,
  ///      ya reproducido y arreglado una vez.
  ///
  /// Si la subida remota falla (red, RLS, etc.), la playlist queda
  /// local-only (sin `remoteId`) -- exactamente el estado seguro de antes de
  /// este fix, que ninguna sincronización toca.
  ///
  /// Devuelve el id **local** (Drift) de la playlist creada, para que el
  /// llamador pueda navegar a ella si quiere.
  Future<int> createPlaylistWithMatchedTracks({
    required String title,
    String? description,
    required List<DeezerTrack> matchedTracks,
    required PlaylistDao dao,
    required DeezerApi deezerApi,
    required SupabasePlaylistRepository supabaseRepo,
  }) async {
    final playlistId = await dao.createPlaylist(title: title, description: description);

    String? remotePlaylistId;
    try {
      final created = await supabaseRepo.createPlaylist(title: title, description: description);
      remotePlaylistId = created['id']?.toString();
    } catch (_) {}

    final remoteTracksPayload = <Map<String, dynamic>>[];
    for (final track in matchedTracks) {
      final contributors = await resolveDeezerTrackContributors(deezerApi, track);
      await dao.addTrackToPlaylist(
        playlistId: playlistId,
        trackId: track.id,
        artistId: track.artistId,
        albumId: track.albumId,
        title: track.title,
        artistName: track.artistName,
        albumName: track.albumTitle,
        coverUrl: track.coverUrl,
        durationMs: track.durationSec * 1000,
        contributorsJson: SyncoraArtistRef.encodeList(contributors),
      );
      if (remotePlaylistId != null) {
        remoteTracksPayload.add({
          'track_id': track.id,
          'artist_id': track.artistId,
          'album_id': track.albumId,
          'title': track.title,
          'artist_name': track.artistName,
          'album_name': track.albumTitle,
          'cover_url': track.coverUrl,
          'duration_ms': track.durationSec * 1000,
          if (contributors.isNotEmpty) 'contributors_json': SyncoraArtistRef.encodeList(contributors),
        });
      }
    }

    if (remotePlaylistId != null && remoteTracksPayload.isNotEmpty) {
      try {
        await supabaseRepo.addTracksToPlaylist(remotePlaylistId, remoteTracksPayload);
        final localPlaylist = await dao.getPlaylistById(playlistId);
        if (localPlaylist != null) {
          await dao.updatePlaylist(localPlaylist.copyWith(remoteId: Value(remotePlaylistId)));
        }
      } catch (_) {
        // Si la subida falla, la playlist se queda sin remoteId -- estado
        // local-only seguro, ninguna sync la toca.
      }
    }

    return playlistId;
  }

  /// Fase 7.F.3, modo "agregar" -- mismo bucle de inserción por pista que
  /// [createPlaylistWithMatchedTracks] (pasos 3-4, D-8), pero sobre una
  /// playlist que **ya existe**: no la crea, no toca su `remoteId` actual.
  /// Si la playlist es local-only ([remotePlaylistId] `null`), solo escribe
  /// en Drift.
  Future<void> addMatchedTracksToExistingPlaylist({
    required int playlistId,
    required String? remotePlaylistId,
    required List<DeezerTrack> matchedTracks,
    required PlaylistDao dao,
    required DeezerApi deezerApi,
    required SupabasePlaylistRepository supabaseRepo,
  }) async {
    final remoteTracksPayload = <Map<String, dynamic>>[];
    for (final track in matchedTracks) {
      final contributors = await resolveDeezerTrackContributors(deezerApi, track);
      await dao.addTrackToPlaylist(
        playlistId: playlistId,
        trackId: track.id,
        artistId: track.artistId,
        albumId: track.albumId,
        title: track.title,
        artistName: track.artistName,
        albumName: track.albumTitle,
        coverUrl: track.coverUrl,
        durationMs: track.durationSec * 1000,
        contributorsJson: SyncoraArtistRef.encodeList(contributors),
      );
      if (remotePlaylistId != null) {
        remoteTracksPayload.add({
          'track_id': track.id,
          'artist_id': track.artistId,
          'album_id': track.albumId,
          'title': track.title,
          'artist_name': track.artistName,
          'album_name': track.albumTitle,
          'cover_url': track.coverUrl,
          'duration_ms': track.durationSec * 1000,
          if (contributors.isNotEmpty) 'contributors_json': SyncoraArtistRef.encodeList(contributors),
        });
      }
    }

    if (remotePlaylistId != null && remoteTracksPayload.isNotEmpty) {
      try {
        await supabaseRepo.addTracksToPlaylist(remotePlaylistId, remoteTracksPayload);
      } catch (_) {
        // Igual que createPlaylistWithMatchedTracks: si la subida remota
        // falla, lo local ya quedó insertado -- se queda desincronizado
        // hasta la próxima sync, no se pierde el trabajo del usuario.
      }
    }
  }

  /// Fase 7.F.3, modo "quitar" -- borra en bloque las entradas ya
  /// confirmadas por el usuario en la vista previa (D-12: el DELETE lo
  /// ejecuta el cliente; la IA solo sugirió cuáles, siempre restringida a
  /// ids ya existentes en la playlist por el `response_schema`, D-7).
  Future<void> removeTracksFromPlaylist({
    required int playlistId,
    required String? remotePlaylistId,
    required List<PlaylistTrack> tracksToRemove,
    required PlaylistDao dao,
    required SupabasePlaylistRepository supabaseRepo,
  }) async {
    if (tracksToRemove.isEmpty) return;
    if (remotePlaylistId != null) {
      try {
        await supabaseRepo.removeTracksFromPlaylist(
          remotePlaylistId,
          tracksToRemove.map((t) => t.trackId).toList(),
        );
      } catch (_) {}
    }
    for (final track in tracksToRemove) {
      await dao.removeTrackEntry(track.id);
    }
  }

  /// Fase 7.I.10 (D-25) -- migración local -> cuenta: sube todas las
  /// playlists locales que todavía no tienen `remoteId` a la nube, tras
  /// registrarse desde el modo local. Solo procesa playlists **sin**
  /// `remoteId`, lo que la hace segura de reintentar sin duplicar
  /// (7.I.16): lo que ya se subió en un intento anterior quedó con
  /// `remoteId` y este método ya no lo vuelve a tocar. Cada playlist se
  /// procesa en su propio `try/catch` para que el fallo de una no aborte
  /// las demás.
  Future<void> migrateLocalPlaylistsToAccount({
    required PlaylistDao dao,
    required SupabasePlaylistRepository supabaseRepo,
  }) async {
    final localPlaylists = await dao.getAllPlaylists();
    final pending = localPlaylists.where((p) => p.remoteId == null).toList();
    if (pending.isEmpty) return;

    // Hallazgo de la revisión independiente: si esta función ya se corrió
    // antes y falló DESPUÉS de crear la playlist remota pero ANTES de
    // marcar `remoteId` local (ej. la subida de tracks falló a mitad de
    // camino), un reintento con el `createPlaylist` ciego de antes creaba
    // una playlist remota duplicada. Se busca primero por título entre las
    // playlists remotas ya existentes del usuario antes de crear una
    // nueva -- cache de una sola consulta, solo se pide si hace falta.
    List<Map<String, dynamic>>? remotePlaylistsCache;
    Future<List<Map<String, dynamic>>> remotePlaylists() async {
      return remotePlaylistsCache ??= await supabaseRepo.fetchUserPlaylists();
    }

    for (final playlist in pending) {
      try {
        String? remoteId;
        if (playlist.isLiked) {
          // Hallazgo de la revisión independiente: `createPlaylist(isLiked:
          // true)` a ciegas puede crear una SEGUNDA "Tus me gusta" si la
          // cuenta ya tenía una (ej. el usuario local inició sesión en una
          // cuenta EXISTENTE, no una recién creada) -- el dedup de
          // `_syncPlaylistsAndTracks` conservaría solo una de las dos
          // arbitrariamente, pudiendo borrar justo la que trae los likes
          // locales recién subidos. `getOrCreateLikedPlaylist()` reusa la
          // liked remota existente si ya hay una.
          final likedRemote = await supabaseRepo.getOrCreateLikedPlaylist();
          remoteId = likedRemote['id']?.toString();
        } else {
          final existing = (await remotePlaylists())
              .where((p) => p['is_liked'] != true && p['title'] == playlist.title)
              .firstOrNull;
          remoteId = existing?['id']?.toString();
          remoteId ??= (await supabaseRepo.createPlaylist(
            title: playlist.title,
            description: playlist.description,
            isPublic: playlist.isPublic,
            isLiked: false,
          ))['id']
              ?.toString();
        }
        if (remoteId == null || remoteId.isEmpty) continue;

        final tracks = await dao.getTracksOrdered(playlist.id);
        final payload = tracks
            .map((t) => {
                  'track_id': t.trackId,
                  'artist_id': t.artistId,
                  'album_id': t.albumId,
                  'title': t.title,
                  'artist_name': t.artistName,
                  'album_name': t.albumName,
                  'cover_url': t.coverUrl,
                  'duration_ms': t.durationMs,
                  if (t.contributorsJson != null) 'contributors_json': t.contributorsJson,
                })
            .toList();
        if (payload.isNotEmpty) {
          await supabaseRepo.addTracksToPlaylist(remoteId, payload);
        }

        await dao.updatePlaylist(playlist.copyWith(remoteId: Value(remoteId)));
      } catch (_) {
        // Esta playlist se reintenta en la próxima llamada -- las que ya
        // llevan `remoteId` de un intento previo no se tocan (idempotente).
      }
    }
  }

  /// Fase 7.I.10 -- complemento de [migrateLocalPlaylistsToAccount]: sube
  /// los álbumes guardados localmente. A diferencia de las playlists, no
  /// hace falta rastrear "ya migrado" -- `SupabaseAlbumRepository.saveAlbum`
  /// hace `upsert(onConflict: 'user_id,album_id')`, así que repetir esta
  /// llamada en un reintento no duplica nada por construcción. Hallazgo de
  /// la revisión independiente: sin este método, el primer `syncLibrary`
  /// tras crear la cuenta podaba (borraba) todos los álbumes guardados
  /// locales que no existieran en el (todavía vacío) remoto.
  Future<void> migrateLocalSavedAlbumsToAccount({
    required SavedAlbumDao savedAlbumDao,
    required SupabaseAlbumRepository supabaseAlbumRepo,
  }) async {
    final localAlbums = await savedAlbumDao.getAllSavedAlbums();
    for (final album in localAlbums) {
      try {
        await supabaseAlbumRepo.saveAlbum({
          'album_id': album.albumId,
          'title': album.title,
          'artist_name': album.artistName,
          'cover_url': album.coverUrl,
        });
      } catch (_) {
        // Se reintenta en la próxima llamada; upsert hace el resto seguro.
      }
    }
  }

  /// Complemento de [migrateLocalPlaylistsToAccount]/
  /// [migrateLocalSavedAlbumsToAccount]: sube el historial de escucha
  /// acumulado en modo local (`listening_history` con `syncedAt` nulo) a la
  /// cuenta recién creada -- sin esto, Estadísticas partía de cero al migrar
  /// (hallazgo verificado: la migración original solo subía playlists y
  /// álbumes). Usa el mismo `upsert` idempotente que el sync normal
  /// (`SupabaseHistoryRepository.insertListeningHistory`, clave natural
  /// `user_id, track_id, listened_at`), así que repetir esta llamada en un
  /// reintento no duplica nada. Cada fila en su propio `try/catch` -- un
  /// fallo no aborta el resto, igual que `migrateLocalSavedAlbumsToAccount`.
  Future<void> migrateLocalListeningHistoryToAccount({
    required ListeningHistoryDao listeningHistoryDao,
    required SupabaseHistoryRepository supabaseHistoryRepo,
  }) async {
    final localEntries = await listeningHistoryDao.getAllUnsyncedHistory();
    for (final entry in localEntries) {
      try {
        await supabaseHistoryRepo.insertListeningHistory(
          trackId: entry.trackId,
          listenedAt: entry.listenedAt,
          artistId: entry.artistId,
          albumId: entry.albumId,
          genre: entry.genre,
          durationListenedMs: entry.durationListenedMs,
        );
        await listeningHistoryDao.markSynced(entry.id);
      } catch (_) {
        // Se reintenta en la próxima llamada; upsert hace el resto seguro.
      }
    }
  }

  /// Export tracks to CSV string format: title,artist,album,duration_ms
  String exportToCsv(List<Map<String, dynamic>> tracksData) {
    final List<List<dynamic>> rows = [
      ['title', 'artist', 'album', 'duration_ms']
    ];

    for (final track in tracksData) {
      rows.add([
        track['title'] ?? '',
        track['artist'] ?? '',
        track['album'] ?? '',
        track['duration_ms'] ?? 0,
      ]);
    }

    return csv.encode(rows);
  }
}
