import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../features/search/search_ranking.dart';
import '../models/deezer/deezer_album.dart';
import '../models/deezer/deezer_artist.dart';
import '../models/deezer/deezer_playlist.dart';
import '../models/deezer/deezer_search_result.dart';
import '../models/deezer/deezer_track.dart';

enum DeezerSearchType { all, track, artist, album, playlist }

/// Rate limiter to respect Deezer's 50 requests / 5 seconds per IP limit.
class RateLimiter {
  final int maxRequests;
  final Duration period;
  final List<DateTime> _requestTimestamps = [];

  RateLimiter({
    this.maxRequests = 45, // Safety margin under 50
    this.period = const Duration(seconds: 5),
  });

  Future<T> run<T>(Future<T> Function() action) async {
    final now = DateTime.now();
    _requestTimestamps.removeWhere((ts) => now.difference(ts) > period);

    if (_requestTimestamps.length >= maxRequests) {
      final oldest = _requestTimestamps.first;
      final waitTime = period - now.difference(oldest);
      if (waitTime > Duration.zero) {
        await Future.delayed(waitTime);
      }
      return run(action);
    }

    _requestTimestamps.add(DateTime.now());
    return action();
  }
}

/// Caché LRU simple e in-memory, reusada para búsquedas, top tracks de artista
/// y detalle de pista (A6 del plan: evitar repetir peticiones ya resueltas).
class _LruCache<K, V> {
  final int maxSize;
  final Map<K, V> _map = {};
  final List<K> _order = [];

  _LruCache({this.maxSize = 20});

  V? get(K key) {
    if (!_map.containsKey(key)) return null;
    _order.remove(key);
    _order.add(key);
    return _map[key];
  }

  void put(K key, V value) {
    _order.remove(key);
    if (_map.length >= maxSize && _order.isNotEmpty) {
      final oldest = _order.removeAt(0);
      _map.remove(oldest);
    }
    _map[key] = value;
    _order.add(key);
  }
}

class DeezerApi {
  final Dio _dio;
  final RateLimiter _rateLimiter;

  final _LruCache<String, DeezerSearchResult> _searchCache = _LruCache(maxSize: 10);
  final _LruCache<int, List<DeezerTrack>> _topTracksCache = _LruCache(maxSize: 20);
  final _LruCache<int, DeezerTrack> _trackCache = _LruCache(maxSize: 30);

  DeezerApi({Dio? dio, RateLimiter? rateLimiter})
      : _dio = dio ?? Dio(BaseOptions(baseUrl: 'https://api.deezer.com')),
        _rateLimiter = rateLimiter ?? RateLimiter();

  Future<DeezerSearchResult> search(String query, {DeezerSearchType type = DeezerSearchType.all}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const DeezerSearchResult();

    final cacheKey = '${type.name}:$trimmed';
    final cached = _searchCache.get(cacheKey);
    if (cached != null) return cached;

    return _rateLimiter.run(() async {
      try {
        List<DeezerTrack> tracks = [];
        List<DeezerArtist> artists = [];
        List<DeezerAlbum> albums = [];
        DeezerArtist? dominantArtist;

        if (type == DeezerSearchType.all) {
          final res = await Future.wait([
            _dio.get('/search', queryParameters: {'q': trimmed, 'limit': 100}),
            _dio.get('/search/artist', queryParameters: {'q': trimmed, 'limit': 100}),
            _dio.get('/search/album', queryParameters: {'q': trimmed, 'limit': 100}),
          ]);

          final trackData = res[0].data;
          final artistData = res[1].data;
          final albumData = res[2].data;

          if (trackData != null && trackData is Map && trackData['data'] is List) {
            for (final item in trackData['data'] as List) {
              if (item is Map && (item['duration'] as int? ?? 0) > 60 && item['type'] != 'podcast') {
                tracks.add(DeezerTrack.fromJson(Map<String, dynamic>.from(item)));
              }
            }
          }

          if (artistData != null && artistData is Map && artistData['data'] is List) {
            for (final item in artistData['data'] as List) {
              if (item is Map) {
                artists.add(DeezerArtist.fromJson(Map<String, dynamic>.from(item)));
              }
            }
            // Ordenar por relevancia de texto + popularidad de fans (ver search_ranking.dart)
            artists = SearchRanking.rankArtists(artists, trimmed);
            dominantArtist = SearchRanking.findDominantArtist(artists, trimmed, tracks);
            // Filtra artistas "novedad" que matchean por nombre pero no tienen
            // ninguna canción real en el pool ya traído (ver "DJ Despacito" en
            // el plan) — gratis, reusa `tracks` ya obtenido en esta búsqueda.
            artists = SearchRanking.filterArtistsWithPresence(artists, tracks);
          }

          if (albumData != null && albumData is Map && albumData['data'] is List) {
            for (final item in albumData['data'] as List) {
              if (item is Map) {
                albums.add(DeezerAlbum.fromJson(Map<String, dynamic>.from(item)));
              }
            }
          }
        } else {
          String endpoint = '/search/track';
          if (type == DeezerSearchType.artist) endpoint = '/search/artist';
          if (type == DeezerSearchType.album) endpoint = '/search/album';

          final response = await _dio.get(endpoint, queryParameters: {'q': trimmed, 'limit': 100});
          if (response.data != null && response.data is Map && response.data['data'] is List) {
            final items = response.data['data'] as List;
            for (final item in items) {
              if (item is! Map) continue;
              final map = Map<String, dynamic>.from(item);
              final typeStr = map['type'] as String? ?? '';

              if (type == DeezerSearchType.track || typeStr == 'track') {
                if ((map['duration'] as int? ?? 0) > 60 && typeStr != 'podcast') {
                  tracks.add(DeezerTrack.fromJson(map));
                }
              } else if (type == DeezerSearchType.artist || typeStr == 'artist') {
                artists.add(DeezerArtist.fromJson(map));
              } else if (type == DeezerSearchType.album || typeStr == 'album') {
                albums.add(DeezerAlbum.fromJson(map));
              }
            }
          }
          if (type == DeezerSearchType.artist) {
            artists = SearchRanking.rankArtists(artists, trimmed);
          }
        }

        tracks = SearchRanking.rankTracks(tracks, trimmed, dominantArtist: dominantArtist);

        // A4: si el artista dominante existe pero sus canciones no aparecen en el
        // top 5 (Deezer las enterró bajo ruido de covers/remixes), traer su top
        // tracks (+1 petición condicional) y re-rankear con ellas incluidas.
        if (type == DeezerSearchType.all && dominantArtist != null) {
          final alreadyOnTop = tracks
              .take(5)
              .any((t) => SearchRanking.trackMatchesArtist(t, dominantArtist!));
          if (!alreadyOnTop) {
            try {
              final topTracks = await getArtistTopTracks(dominantArtist.id);
              final existingIds = tracks.map((t) => t.id).toSet();
              final newOnes = topTracks.where((t) => existingIds.add(t.id)).take(10);
              if (newOnes.isNotEmpty) {
                tracks = SearchRanking.rankTracks(
                  [...tracks, ...newOnes],
                  trimmed,
                  dominantArtist: dominantArtist,
                );
              }
            } catch (_) {}
          }
        }

        // A5: enriquecer con /track/{id} solo los títulos que aparecen más de una
        // vez entre los primeros resultados (mismo título base + artista) — es
        // justo ahí donde el usuario no puede distinguir una colaboración de una
        // versión solista, porque /search no trae `contributors`.
        tracks = await _enrichAmbiguousTitles(tracks);

        final result = DeezerSearchResult(
          tracks: tracks,
          artists: artists,
          albums: albums,
        );

        _searchCache.put(cacheKey, result);

        return result;
      } catch (e) {
        if (kDebugMode) {
          print('DeezerApi search error: $e');
        }
        rethrow;
      }
    });
  }

  /// A5: agrupa los primeros [_ambiguousScanLimit] resultados por título base +
  /// artista; para cada grupo con más de un miembro (ej. "3 A.M." y "3 A.M.
  /// (feat. Tommy Torres)"), pide el detalle completo vía `getTrack` para poder
  /// mostrar quién colabora en cada uno.
  ///
  /// Extendido (A5b): esto por sí solo dejaba huecos inconsistentes — "3 A.M."
  /// o "Despacito" se enriquecían por casualidad (Deezer repite el mismo
  /// título+artista más de una vez en el pool), pero canciones como "Un Día
  /// (One Day)" no tienen ningún duplicado ni ninguna pista en el texto del
  /// título — así que nunca se enriquecían, pese a ser justo los primeros
  /// resultados que el usuario ve. Por eso los primeros [_alwaysEnrichTop]
  /// tracks del ranking final SIEMPRE entran como candidatos, tengan o no
  /// duplicado. Sigue respetando el mismo tope de [_ambiguousMaxRequests]
  /// peticiones ya presupuestado en el plan — no se añade presupuesto nuevo,
  /// solo se prioriza mejor a quién se le gasta.
  ///
  /// Se descartó extraer el colaborador directo del texto del título (gratis,
  /// sin request) porque esos nombres no traen `artistId` real de Deezer —
  /// saldrían como texto no clickeable en la UI, inconsistente con el resto
  /// de artistas. Se prefiere pagar la petición y tener siempre un ID real.
  static const int _ambiguousScanLimit = 20;
  static const int _alwaysEnrichTop = 5;
  static const int _ambiguousMaxRequests = 8;

  Future<List<DeezerTrack>> _enrichAmbiguousTitles(List<DeezerTrack> tracks) async {
    final scanned = tracks.take(_ambiguousScanLimit).toList();
    final groups = <String, List<DeezerTrack>>{};
    for (final t in scanned) {
      final key = '${SearchRanking.baseTitle(t.title)}|${SearchRanking.normalize(t.artistName)}';
      (groups[key] ??= []).add(t);
    }

    final candidates = <int, DeezerTrack>{};
    for (final t in tracks.take(_alwaysEnrichTop)) {
      if (t.contributorsList.length <= 1) candidates[t.id] = t;
    }
    for (final group in groups.values) {
      if (group.length <= 1) continue;
      for (final t in group) {
        if (t.contributorsList.length <= 1) candidates[t.id] = t;
      }
    }

    final toEnrich = candidates.values.take(_ambiguousMaxRequests);
    if (toEnrich.isEmpty) return tracks;

    // En paralelo, no secuencial: con el top-5 siempre incluido esto pasó de
    // 0-2 peticiones típicas a hasta 5+, y en secuencia cada una suma su
    // latencia completa (~3s percibidos). El RateLimiter ya soporta llamadas
    // concurrentes (lo mismo hace el fetch inicial de tracks/artistas/álbumes
    // de más arriba) y encola en vez de fallar si se pasa del límite.
    final result = List<DeezerTrack>.from(tracks);
    await Future.wait(toEnrich.map((original) async {
      try {
        final full = await getTrack(original.id);
        if (full.contributorsList.length > 1) {
          final pos = result.indexWhere((t) => t.id == original.id);
          if (pos != -1) result[pos] = original.withContributors(full.contributorsList);
        }
      } catch (_) {}
    }));
    return result;
  }

  Future<DeezerTrack> getTrack(int id) async {
    final cached = _trackCache.get(id);
    if (cached != null) return cached;

    return _rateLimiter.run(() async {
      final response = await _dio.get('/track/$id');
      final track = DeezerTrack.fromJson(Map<String, dynamic>.from(response.data as Map));
      _trackCache.put(id, track);
      return track;
    });
  }

  Future<DeezerAlbum> getAlbum(int id) async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/album/$id');
      return DeezerAlbum.fromJson(Map<String, dynamic>.from(response.data as Map));
    });
  }

  Future<DeezerArtist> getArtist(int id) async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/artist/$id');
      return DeezerArtist.fromJson(Map<String, dynamic>.from(response.data as Map));
    });
  }

  Future<List<DeezerTrack>> getArtistTopTracks(int id) async {
    final cached = _topTracksCache.get(id);
    if (cached != null) return cached;

    return _rateLimiter.run(() async {
      final response = await _dio.get('/artist/$id/top');
      if (response.data == null || response.data['data'] is! List) return [];
      final list = response.data['data'] as List;
      final tracks = list
          .where((item) => (item['duration'] as int? ?? 0) > 60 && item['type'] != 'podcast')
          .map((item) => DeezerTrack.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();
      tracks.sort((a, b) => (b.rank ?? 0).compareTo(a.rank ?? 0));
      _topTracksCache.put(id, tracks);
      return tracks;
    });
  }

  Future<List<DeezerAlbum>> getArtistAlbums(int id) async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/artist/$id/albums');
      if (response.data == null || response.data['data'] is! List) return [];
      final list = response.data['data'] as List;
      final albums = list.map((item) => DeezerAlbum.fromJson(Map<String, dynamic>.from(item as Map))).toList();
      albums.sort((a, b) {
        if (a.releaseDate.isEmpty) return 1;
        if (b.releaseDate.isEmpty) return -1;
        return b.releaseDate.compareTo(a.releaseDate);
      });
      return albums;
    });
  }

  /// Obtiene recomendaciones de pistas basadas en una pista origen (/track/$trackId/related)
  Future<List<DeezerTrack>> getTrackRecommendations(int trackId) async {
    return _rateLimiter.run(() async {
      try {
        final response = await _dio.get('/track/$trackId/related');
        if (response.data != null && response.data['data'] is List) {
          final list = response.data['data'] as List;
          final tracks = list
              .where((item) => (item['duration'] as int? ?? 0) > 60 && item['type'] != 'podcast')
              .map((item) => DeezerTrack.fromJson(Map<String, dynamic>.from(item as Map)))
              .toList();
          if (tracks.isNotEmpty) {
            tracks.sort((a, b) => (b.rank ?? 0).compareTo(a.rank ?? 0));
            return tracks;
          }
        }
      } catch (e) {
        if (kDebugMode) {
          print('Error en getTrackRecommendations /track/$trackId/related: $e');
        }
      }

      // Fallback 1: obtener pista origen e intentar top tracks del artista
      try {
        final sourceTrack = await getTrack(trackId);
        if (sourceTrack.artistId > 0) {
          final artistTracks = await getArtistTopTracks(sourceTrack.artistId);
          final filtered = artistTracks.where((t) => t.id != trackId).toList();
          if (filtered.isNotEmpty) return filtered;
        }
      } catch (_) {}

      // Fallback 2: Top Charts globales
      return getTopCharts();
    });
  }

  /// Obtiene playlists editoriales (/chart/0/playlists)
  Future<List<DeezerPlaylist>> getEditorialPlaylists() async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/chart/0/playlists');
      if (response.data == null || response.data['data'] is! List) return [];
      final list = response.data['data'] as List;
      return list.map((item) => DeezerPlaylist.fromJson(Map<String, dynamic>.from(item as Map))).toList();
    });
  }

  /// Obtiene el top de canciones globales (/chart/0/tracks)
  Future<List<DeezerTrack>> getTopCharts() async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/chart/0/tracks');
      if (response.data == null || response.data['data'] is! List) return [];
      final list = response.data['data'] as List;
      final tracks = list
          .where((item) => (item['duration'] as int? ?? 0) > 60 && item['type'] != 'podcast')
          .map((item) => DeezerTrack.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();
      tracks.sort((a, b) => (b.rank ?? 0).compareTo(a.rank ?? 0));
      return tracks;
    });
  }

  /// Obtiene nuevos lanzamientos de álbumes (/chart/0/albums)
  Future<List<DeezerAlbum>> getNewReleases() async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/chart/0/albums');
      if (response.data == null || response.data['data'] is! List) return [];
      final list = response.data['data'] as List;
      return list.map((item) => DeezerAlbum.fromJson(Map<String, dynamic>.from(item as Map))).toList();
    });
  }
}

