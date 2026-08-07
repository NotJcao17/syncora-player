import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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

class DeezerApi {
  final Dio _dio;
  final RateLimiter _rateLimiter;

  // Simple in-memory LRU cache for last 10 search queries
  final Map<String, DeezerSearchResult> _searchCache = {};
  final List<String> _cacheKeysOrder = [];

  DeezerApi({Dio? dio, RateLimiter? rateLimiter})
      : _dio = dio ?? Dio(BaseOptions(baseUrl: 'https://api.deezer.com')),
        _rateLimiter = rateLimiter ?? RateLimiter();

  Future<DeezerSearchResult> search(String query, {DeezerSearchType type = DeezerSearchType.all}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const DeezerSearchResult();

    final cacheKey = '${type.name}:$trimmed';
    if (_searchCache.containsKey(cacheKey)) {
      _cacheKeysOrder.remove(cacheKey);
      _cacheKeysOrder.add(cacheKey);
      return _searchCache[cacheKey]!;
    }

    return _rateLimiter.run(() async {
      try {
        List<DeezerTrack> tracks = [];
        List<DeezerArtist> artists = [];
        List<DeezerAlbum> albums = [];

        if (type == DeezerSearchType.all) {
          final res = await Future.wait([
            _dio.get('/search', queryParameters: {'q': trimmed}),
            _dio.get('/search/artist', queryParameters: {'q': trimmed}),
            _dio.get('/search/album', queryParameters: {'q': trimmed}),
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
            // En la pestaña "Todo", filtrar para conservar solo artistas realmente relevantes
            final queryLower = trimmed.toLowerCase();
            artists = artists.where((a) {
              final artistNameLower = a.name.toLowerCase();
              final isExactMatch = artistNameLower == queryLower;
              final isPartialMatch = artistNameLower.contains(queryLower) || queryLower.contains(artistNameLower);
              final hasHighFanCount = a.nbFan >= 1000;
              return isExactMatch || (isPartialMatch && hasHighFanCount);
            }).toList();
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

          final response = await _dio.get(endpoint, queryParameters: {'q': trimmed});
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
        }

        // Ordenar canciones por popularidad/rank descendente
        tracks.sort((a, b) => (b.rank ?? 0).compareTo(a.rank ?? 0));

        final result = DeezerSearchResult(
          tracks: tracks,
          artists: artists,
          albums: albums,
        );

        // Put in cache LRU (max 10)
        _cacheKeysOrder.remove(cacheKey);
        if (_searchCache.length >= 10 && _cacheKeysOrder.isNotEmpty) {
          final oldestKey = _cacheKeysOrder.removeAt(0);
          _searchCache.remove(oldestKey);
        }
        _searchCache[cacheKey] = result;
        _cacheKeysOrder.add(cacheKey);

        return result;
      } catch (e) {
        if (kDebugMode) {
          print('DeezerApi search error: $e');
        }
        rethrow;
      }
    });
  }

  Future<DeezerTrack> getTrack(int id) async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/track/$id');
      return DeezerTrack.fromJson(Map<String, dynamic>.from(response.data as Map));
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
    return _rateLimiter.run(() async {
      final response = await _dio.get('/artist/$id/top');
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

  Future<List<DeezerAlbum>> getArtistAlbums(int id) async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/artist/$id/albums');
      if (response.data == null || response.data['data'] is! List) return [];
      final list = response.data['data'] as List;
      return list.map((item) => DeezerAlbum.fromJson(Map<String, dynamic>.from(item as Map))).toList();
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

