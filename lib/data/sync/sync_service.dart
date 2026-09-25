// ignore_for_file: prefer_initializing_formals

import 'dart:io';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../local_db/daos/listening_history_dao.dart';
import '../local_db/daos/playlist_dao.dart';
import '../local_db/daos/saved_album_dao.dart';
import '../local_db/database_provider.dart';
import '../local_db/syncora_database.dart';
import '../supabase/supabase_album_repository.dart';
import '../supabase/supabase_history_repository.dart';
import '../supabase/supabase_playlist_repository.dart';
import '../supabase/supabase_providers.dart';
import 'sync_cache_manager.dart';

class SyncService {
  final SupabasePlaylistRepository _playlistRepo;
  final SupabaseAlbumRepository _albumRepo;
  final SupabaseHistoryRepository _historyRepo;
  final PlaylistDao _playlistDao;
  final SavedAlbumDao _savedAlbumDao;
  final ListeningHistoryDao _listeningHistoryDao;
  final SyncCacheManager _cacheManager;

  SyncService({
    required SupabasePlaylistRepository playlistRepo,
    required SupabaseAlbumRepository albumRepo,
    required SupabaseHistoryRepository historyRepo,
    required PlaylistDao playlistDao,
    required SavedAlbumDao savedAlbumDao,
    required ListeningHistoryDao listeningHistoryDao,
    required SyncCacheManager cacheManager,
  })  : _playlistRepo = playlistRepo,
        _albumRepo = albumRepo,
        _historyRepo = historyRepo,
        _playlistDao = playlistDao,
        _savedAlbumDao = savedAlbumDao,
        _listeningHistoryDao = listeningHistoryDao,
        _cacheManager = cacheManager;

  bool get _isTestEnv => Platform.environment.containsKey('FLUTTER_TEST');

  /// Corridas en vuelo, por operación.
  ///
  /// **Bug real, encontrado en pruebas en dispositivo:** hay tres disparadores
  /// de `syncLibrary` que pueden coincidir en el tiempo — iniciar sesión
  /// (`auth_screen`), arrancar la app (`AppShell.initState`) y abrir
  /// Biblioteca. El chequeo `!_cacheManager.isExpired(...)` no alcanzaba para
  /// serializarlos porque `markSynced` se escribe recién **al terminar**: las
  /// tres corridas pasaban el chequeo, las tres leían la base local vacía y
  /// las tres insertaban lo mismo. En una instalación nueva sobre una cuenta
  /// ya poblada eso dejaba cada playlist duplicada y cada pista de "Tus me
  /// gusta" duplicada.
  ///
  /// Con esto, quien llegue segundo **espera a la corrida en curso** en vez de
  /// empezar otra en paralelo.
  final Map<String, Future<void>> _inFlight = {};

  Future<void> _runExclusive(String key, Future<void> Function() action) {
    final existing = _inFlight[key];
    if (existing != null) return existing;

    // Cuerpo de bloque, NO flecha: `Map.remove` devuelve el valor quitado —
    // que acá es el propio `Future` que estamos registrando— y `whenComplete`
    // espera a lo que su callback devuelva. Con `() => _inFlight.remove(key)`
    // el future terminaba esperándose a sí mismo y la sincronización se
    // colgaba para siempre (los tests de `SyncService` se quedaban en timeout).
    final future = action().whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  Future<void> syncOnStartup() async {
    if (_isTestEnv) return;

    try {
      final currentUser = Supabase.instance.client.auth.currentUser;
      if (currentUser == null) {
        return;
      }
    } catch (_) {
      return;
    }

    await syncLibrary(force: false);
    await syncSavedAlbums(force: false);
    await syncListeningHistory();
  }

  Future<void> syncLibrary({bool force = false}) async {
    if (!force && !_cacheManager.isExpired('library')) {
      return;
    }

    return _runExclusive('library', () async {
      try {
        await _syncPlaylistsAndTracks();
        await _syncSavedAlbumsInternal();
        _cacheManager.markSynced('library');
      } catch (_) {
        // Network/offline error caught silently, fallback to local DB
      }
    });
  }

  Future<void> syncPlaylistDetail(String playlistRemoteId, {bool force = false}) async {
    final cacheKey = 'playlist_$playlistRemoteId';
    if (!force && !_cacheManager.isExpired(cacheKey)) {
      return;
    }

    try {
      final remotePlaylists = await _playlistRepo.fetchUserPlaylists();
      final existsRemote = remotePlaylists.any((p) => p['id']?.toString() == playlistRemoteId);

      if (!existsRemote) {
        final localPlaylist = await _playlistDao.getPlaylistByRemoteId(playlistRemoteId);
        if (localPlaylist != null && !localPlaylist.isLiked) {
          await _playlistDao.deletePlaylist(localPlaylist.id);
        }
        _cacheManager.invalidate('playlist_$playlistRemoteId');
        _cacheManager.invalidate('library');
        return;
      }

      final remoteTracks = await _playlistRepo.fetchPlaylistTracks(playlistRemoteId);
      final localPlaylist = await _playlistDao.getPlaylistByRemoteId(playlistRemoteId);

      if (localPlaylist != null) {
        final localTracks = await _playlistDao.getTracksOrdered(localPlaylist.id);
        final localTrackIds = localTracks.map((t) => t.trackId).toSet();
        final remoteTrackIds = remoteTracks.map((t) => (t['track_id'] as num).toInt()).toSet();

        // Pruning local tracks not in remote
        for (final localTrack in localTracks) {
          if (!remoteTrackIds.contains(localTrack.trackId)) {
            await _playlistDao.removeTrackFromPlaylist(localPlaylist.id, localTrack.trackId);
          }
        }

        // Adding remote tracks not in local
        for (final trackMap in remoteTracks) {
          final trackId = (trackMap['track_id'] as num).toInt();

          if (!localTrackIds.contains(trackId)) {
            await _playlistDao.addTrackToPlaylist(
              playlistId: localPlaylist.id,
              trackId: trackId,
              artistId: (trackMap['artist_id'] as num?)?.toInt() ?? 0,
              albumId: (trackMap['album_id'] as num?)?.toInt() ?? 0,
              title: trackMap['title'] as String? ?? '',
              artistName: trackMap['artist_name'] as String? ?? '',
              albumName: trackMap['album_name'] as String? ?? '',
              coverUrl: trackMap['cover_url'] as String? ?? '',
              durationMs: (trackMap['duration_ms'] as num?)?.toInt() ?? 0,
              genre: trackMap['genre'] as String?,
              contributorsJson: trackMap['contributors_json'] as String?,
            );
          }
        }
      }
      _cacheManager.markSynced(cacheKey);
    } catch (_) {
      // Network/offline error caught silently, fallback to local DB
    }
  }

  Future<void> syncSavedAlbums({bool force = false}) async {
    if (!force && !_cacheManager.isExpired('saved_albums')) {
      return;
    }

    return _runExclusive('saved_albums', () async {
      try {
        await _syncSavedAlbumsInternal();
        _cacheManager.markSynced('saved_albums');
      } catch (_) {
        // Network/offline error caught silently, fallback to local DB
      }
    });
  }

  Future<void> syncListeningHistory() async {
    return _runExclusive('listening_history', () async {
      try {
        await _syncListeningHistoryInternal();
      } catch (_) {
        // Network/offline error caught silently
      }
    });
  }

  /// Cooldown corto (no los 5 min por defecto de [SyncCacheManager]) para el
  /// disparo reactivo desde `SyncoraPlayerController.onListenRecorded`:
  /// investigación de estadísticas, root cause de "el PC no ve las escuchas
  /// del celular hasta tocar Actualizar ahí" -- antes, subir el historial
  /// solo pasaba en `syncOnStartup()` o al tocar el botón manual de
  /// Estadísticas, nunca como reacción directa a grabar una escucha. Separado
  /// de [syncListeningHistory] (sin cooldown, usado por el botón manual y el
  /// arranque, que deben ejecutar siempre) para no cambiarle el
  /// comportamiento a esos otros llamadores -- sin esto, escuchar varias
  /// pistas cortas seguidas dispararía un upsert de red por cada una.
  static const _listeningHistoryPushCooldown = Duration(seconds: 30);

  Future<void> pushListeningHistoryIfDue() async {
    if (!_cacheManager.isExpired(
      'listening_history_push',
      customTtl: _listeningHistoryPushCooldown,
    )) {
      return;
    }
    _cacheManager.markSynced('listening_history_push');
    await syncListeningHistory();
  }

  /// Quita pistas repetidas (mismo `track_id`) de lo que llega del servidor.
  ///
  /// Sin esto, una fila duplicada en `playlist_tracks` de Supabase se copiaba
  /// tal cual a la base local en cada sincronización: el bucle de inserción
  /// recorre la lista completa, mientras que el de poda compara contra un
  /// conjunto, así que el duplicado nunca se eliminaba.
  static List<Map<String, dynamic>> _dedupeRemoteTracks(List<Map<String, dynamic>> tracks) {
    final seen = <int>{};
    final out = <Map<String, dynamic>>[];
    for (final track in tracks) {
      final id = (track['track_id'] as num?)?.toInt();
      if (id == null || !seen.add(id)) continue;
      out.add(track);
    }
    return out;
  }

  Future<void> _syncPlaylistsAndTracks() async {
    final remotePlaylists = await _playlistRepo.fetchUserPlaylists();

    // Liked Playlist Deduplication
    final likedRemotePlaylists = remotePlaylists.where((p) => p['is_liked'] == true).toList();
    if (likedRemotePlaylists.length > 1) {
      final officialRemoteLiked = likedRemotePlaylists.first;
      final officialId = officialRemoteLiked['id']?.toString();
      for (int i = 1; i < likedRemotePlaylists.length; i++) {
        final dupId = likedRemotePlaylists[i]['id']?.toString();
        if (dupId != null) {
          await _playlistRepo.deletePlaylist(dupId);
        }
      }
      remotePlaylists.removeWhere((p) => p['is_liked'] == true && p['id']?.toString() != officialId);
    }

    final localPlaylists = await _playlistDao.getAllPlaylists();
    final remoteIdsSet = <String>{};

    for (final remote in remotePlaylists) {
      final String remoteId = remote['id'].toString();
      remoteIdsSet.add(remoteId);

      final String title = remote['title'] as String? ?? 'Untitled';
      final String? description = remote['description'] as String?;
      final String? coverUrl = remote['cover_url'] as String?;
      final bool isLiked = remote['is_liked'] as bool? ?? false;
      final bool isPublic = remote['is_public'] as bool? ?? false;
      // Ronda 4: fijar viaja a Supabase, así que la nube manda igual que con
      // el resto de campos. Antes el sync nunca lo leía.
      final bool isPinned = remote['is_pinned'] as bool? ?? false;

      int localPlaylistId;

      if (isLiked) {
        final likedPlaylist = await _playlistDao.getLikedPlaylist();
        localPlaylistId = likedPlaylist.id;
        if (likedPlaylist.remoteId != remoteId || likedPlaylist.isPinned != isPinned) {
          await _playlistDao.updatePlaylist(
              likedPlaylist.copyWith(remoteId: Value(remoteId), isPinned: isPinned));
        }
      } else {
        Playlist? match = await _playlistDao.getPlaylistByRemoteId(remoteId);
        // `isGenerated` excluido a propósito: "On Repeat" es una playlist que
        // mantiene la app y que nunca se sube, así que una playlist remota que
        // se llamara igual no debe adoptarla — la convertiría en una playlist
        // normal sincronizada y se perdería la regeneración semanal.
        match ??= localPlaylists
            .where((p) => p.title == title && !p.isLiked && !p.isGenerated)
            .firstOrNull;

        if (match != null) {
          localPlaylistId = match.id;
          await _playlistDao.updatePlaylist(
            match.copyWith(
              remoteId: Value(remoteId),
              title: title,
              description: Value(description),
              coverUrl: Value(coverUrl),
              isPublic: isPublic,
              isPinned: isPinned,
            ),
          );
        } else {
          localPlaylistId = await _playlistDao.createPlaylist(
            title: title,
            description: description,
            coverUrl: coverUrl,
            remoteId: remoteId,
            isPublic: isPublic,
            isPinned: isPinned,
          );
        }
      }

      final remoteTracks = _dedupeRemoteTracks(
        await _playlistRepo.fetchPlaylistTracks(remoteId),
      );
      final localTracks =
          await _playlistDao.getTracksOrdered(localPlaylistId);
      final localTrackIds = localTracks.map((t) => t.trackId).toSet();
      final remoteTrackIds = remoteTracks.map((t) => (t['track_id'] as num).toInt()).toSet();

      // Pruning local tracks not in remote
      for (final localTrack in localTracks) {
        if (!remoteTrackIds.contains(localTrack.trackId)) {
          await _playlistDao.removeTrackFromPlaylist(localPlaylistId, localTrack.trackId);
        }
      }

      // Adding remote tracks not in local
      for (final trackMap in remoteTracks) {
        final trackId = (trackMap['track_id'] as num).toInt();

        if (!localTrackIds.contains(trackId)) {
          await _playlistDao.addTrackToPlaylist(
            playlistId: localPlaylistId,
            trackId: trackId,
            artistId: (trackMap['artist_id'] as num?)?.toInt() ?? 0,
            albumId: (trackMap['album_id'] as num?)?.toInt() ?? 0,
            title: trackMap['title'] as String? ?? '',
            artistName: trackMap['artist_name'] as String? ?? '',
            albumName: trackMap['album_name'] as String? ?? '',
            coverUrl: trackMap['cover_url'] as String? ?? '',
            durationMs: (trackMap['duration_ms'] as num?)?.toInt() ?? 0,
            genre: trackMap['genre'] as String?,
            contributorsJson: trackMap['contributors_json'] as String?,
          );
        }
      }
    }

    for (final localP in localPlaylists) {
      if (!localP.isLiked &&
          localP.remoteId != null &&
          !remoteIdsSet.contains(localP.remoteId)) {
        await _playlistDao.deletePlaylist(localP.id);
      }
    }

    final likedPlaylist = await _playlistDao.getLikedPlaylist();
    if (likedPlaylist.remoteId == null) {
      final recheckRemote = await _playlistRepo.fetchUserPlaylists();
      final existingLiked = recheckRemote.where((p) => p['is_liked'] == true).firstOrNull;
      if (existingLiked != null) {
        final remoteId = existingLiked['id']?.toString();
        if (remoteId != null && remoteId.isNotEmpty) {
          await _playlistDao.updatePlaylist(likedPlaylist.copyWith(remoteId: Value(remoteId)));
        }
      } else {
        final created = await _playlistRepo.getOrCreateLikedPlaylist();
        final remoteId = created['id']?.toString();
        if (remoteId != null && remoteId.isNotEmpty) {
          await _playlistDao.updatePlaylist(likedPlaylist.copyWith(remoteId: Value(remoteId)));
        }
      }
    }
  }

  Future<void> _syncSavedAlbumsInternal() async {
    final remoteAlbums = await _albumRepo.fetchSavedAlbums();
    final remoteAlbumIds = <int>{};
    for (final albumMap in remoteAlbums) {
      final albumId = (albumMap['album_id'] as num).toInt();
      remoteAlbumIds.add(albumId);
      final title = albumMap['title'] as String? ?? '';
      final artistName = albumMap['artist_name'] as String? ?? '';
      final coverUrl = albumMap['cover_url'] as String? ?? '';

      await _savedAlbumDao.saveAlbum(
        albumId: albumId,
        title: title,
        artistName: artistName,
        coverUrl: coverUrl,
      );
    }

    final localSavedAlbums = await _savedAlbumDao.getAllSavedAlbums();
    for (final localAlbum in localSavedAlbums) {
      if (!remoteAlbumIds.contains(localAlbum.albumId)) {
        await _savedAlbumDao.removeSavedAlbum(localAlbum.albumId);
      }
    }
  }

  // Fase 7.0.1: antes leía las últimas 100 entradas locales (sin importar si
  // ya se habían subido) y las insertaba con un `.insert()` plano — cada
  // sync reinsertaba las mismas filas. Ahora selecciona solo las pendientes
  // (`syncedAt` nulo) y marca cada una como sincronizada únicamente tras un
  // upsert remoto exitoso, entrada por entrada.
  /// Ventana de historial que se baja de la nube.
  ///
  /// 90 días cubre de sobra lo que consumen las secciones derivadas (On Repeat
  /// mira 30 días; los mixes y "Novedades de tus artistas", 60) sin arrastrar
  /// el historial completo en cada sincronización.
  static const Duration _historyPullWindow = Duration(days: 90);

  Future<void> _syncListeningHistoryInternal() async {
    await _pushPendingHistory();
    await _pullRemoteHistory();
  }

  /// Baja el historial de los otros dispositivos.
  ///
  /// Sin esto, `listening_history` local era "lo que escuché en este aparato":
  /// On Repeat, los mixes y "Novedades de tus artistas" salían distintos en el
  /// PC que en el móvil. Los fallos se tragan en silencio como el resto del
  /// sync — es contenido derivado, no datos que el usuario pueda perder.
  Future<void> _pullRemoteHistory() async {
    final since = DateTime.now().subtract(_historyPullWindow);

    final remote = await _historyRepo.fetchListeningHistory(since: since);
    if (remote.isEmpty) return;

    final companions = <ListeningHistoryCompanion>[];
    for (final row in remote) {
      final trackId = (row['track_id'] as num?)?.toInt();
      final listenedAtRaw = row['listened_at'];
      if (trackId == null || listenedAtRaw is! String) continue;

      final listenedAt = DateTime.tryParse(listenedAtRaw);
      if (listenedAt == null) continue;

      companions.add(ListeningHistoryCompanion.insert(
        trackId: trackId,
        artistId: (row['artist_id'] as num?)?.toInt() ?? 0,
        albumId: (row['album_id'] as num?)?.toInt() ?? 0,
        durationListenedMs: (row['duration_listened_ms'] as num?)?.toInt() ?? 0,
        genre: Value(row['genre'] as String?),
        listenedAt: Value(listenedAt.toLocal()),
        // Ya está en la nube: sin esto el siguiente push la volvería a subir.
        syncedAt: Value(DateTime.now()),
        // H-S3: no se grabó en este aparato, así que el dedupe de escuchas
        // no debe reutilizarla nunca.
        fromRemote: const Value(true),
      ));
    }

    await _listeningHistoryDao.insertRemoteEntries(companions);
  }

  /// Cuántas escuchas viajan en cada petición (H-S4).
  ///
  /// 200 filas son ~20 KB de JSON: cómodo para PostgREST y para el plan free,
  /// y reduce un backlog de 1000 escuchas de 1000 peticiones a 5.
  static const int _historyPushChunkSize = 200;

  Future<void> _pushPendingHistory() async {
    final pending = await _listeningHistoryDao.getUnsyncedHistory();
    if (pending.isEmpty) return;

    // La clave de conflicto es (user_id, track_id, listened_at). Si dos filas
    // locales cayeran en el mismo segundo para la misma pista, Postgres
    // rechazaría el lote entero ("cannot affect row a second time"), así que
    // se deduplica antes de enviar quedándose con la más completa.
    final byKey = <String, ListeningHistoryData>{};
    for (final e in pending) {
      final key = '${e.trackId}@${e.listenedAt.toUtc().toIso8601String()}';
      final existing = byKey[key];
      if (existing == null || e.durationListenedMs > existing.durationListenedMs) {
        byKey[key] = e;
      }
    }
    final unique = byKey.values.toList();

    for (var i = 0; i < unique.length; i += _historyPushChunkSize) {
      final chunk = unique.skip(i).take(_historyPushChunkSize).toList();
      try {
        final ok = await _historyRepo.insertListeningHistoryBatch([
          for (final e in chunk)
            {
              'track_id': e.trackId,
              'artist_id': e.artistId,
              'album_id': e.albumId,
              'genre': e.genre,
              'duration_listened_ms': e.durationListenedMs,
              'listened_at': e.listenedAt,
            },
        ]);
        if (!ok) break;
        await _listeningHistoryDao.markManySynced([for (final e in chunk) e.id]);
      } catch (_) {
        // No marcar como sincronizadas: se reintentará en el próximo sync.
        // Se detiene el resto porque un fallo aquí suele ser de red/auth y
        // afectaría igual a los lotes siguientes.
        break;
      }
    }
  }
}

final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService(
    playlistRepo: ref.watch(supabasePlaylistRepositoryProvider),
    albumRepo: ref.watch(supabaseAlbumRepositoryProvider),
    historyRepo: ref.watch(supabaseHistoryRepositoryProvider),
    playlistDao: ref.watch(playlistDaoProvider),
    savedAlbumDao: ref.watch(savedAlbumDaoProvider),
    listeningHistoryDao: ref.watch(listeningHistoryDaoProvider),
    cacheManager: ref.watch(syncCacheManagerProvider),
  );
});
