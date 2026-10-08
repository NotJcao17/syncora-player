import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../features/search/search_ranking.dart';
import 'canonical_version_resolver.dart';
import '../models/deezer/deezer_album.dart';
import '../models/deezer/deezer_artist.dart';
import '../models/deezer/deezer_genre.dart';
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

/// El recurso ya no existe en el catálogo de Deezer (lo retiró el sello o la
/// distribuidora). Pasa de vez en cuando con lanzamientos independientes.
class DeezerNotFoundException implements Exception {
  final String path;
  const DeezerNotFoundException(this.path);

  @override
  String toString() => 'DeezerNotFoundException($path)';
}

class DeezerApi {
  final Dio _dio;
  final RateLimiter _rateLimiter;

  final _LruCache<String, DeezerSearchResult> _searchCache = _LruCache(maxSize: 10);
  final _LruCache<String, List<DeezerTrack>> _topTracksCache = _LruCache(maxSize: 20);
  final _LruCache<int, DeezerTrack> _trackCache = _LruCache(maxSize: 30);
  final _LruCache<int, List<DeezerTrack>> _artistRadioCache = _LruCache(maxSize: 20);
  final _LruCache<int, List<DeezerArtist>> _artistRelatedCache = _LruCache(maxSize: 20);

  DeezerApi({Dio? dio, RateLimiter? rateLimiter})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://api.deezer.com',
              // Revisión de 7.B (bug #5): sin timeouts, un socket colgado
              // (ej. cambio de red en móvil a medio fetch) dejaba cualquier
              // `await` sobre este Dio sin resolver nunca — en el caso de
              // radio, eso trababa `_isFetchingRadio` en `true` el resto de
              // la sesión. Cambio general de robustez para toda la API, no
              // solo para radio.
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
            )),
        _rateLimiter = rateLimiter ?? RateLimiter();

  /// [enrich] `false` omite el paso A5 (`/track/{id}` de los primeros
  /// resultados para mostrar colaboradores) — ronda 4, H-R4-9. El buscador
  /// pinta primero sin él y lo completa después con [enrichSearchResult]; la
  /// importación y la búsqueda exacta solo necesitan el mejor candidato, y
  /// ahí esas hasta 8 peticiones extra por consulta eran puro coste.
  Future<DeezerSearchResult> search(
    String query, {
    DeezerSearchType type = DeezerSearchType.all,
    bool enrich = true,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const DeezerSearchResult();

    final cacheKey = '${type.name}:$trimmed';
    final cached = _searchCache.get(cacheKey);
    if (cached != null) return cached;
    if (!enrich) {
      final raw = _searchCache.get('$cacheKey#raw');
      if (raw != null) return raw;
    }

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
          if (type == DeezerSearchType.playlist) {
            final playlists = await searchPlaylists(trimmed);
            final result = DeezerSearchResult(playlists: playlists);
            _searchCache.put(cacheKey, result);
            _searchCache.put('$cacheKey#raw', result);
            return result;
          }

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

        if (!enrich) {
          final raw = DeezerSearchResult(tracks: tracks, artists: artists, albums: albums);
          _searchCache.put('$cacheKey#raw', raw);
          return raw;
        }

        // A5: enriquecer con /track/{id} solo los títulos que aparecen más de una
        // vez entre los primeros resultados (mismo título base + artista) — es
        // justo ahí donde el usuario no puede distinguir una colaboración de una
        // versión solista, porque /search no trae `contributors`.
        tracks = await _enrichAmbiguousTitles(await canonicalResolver.resolveTop(tracks));

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
  /// Segunda fase de [search] con `enrich: false` (ronda 4): aplica A5 sobre
  /// un resultado ya pintado y lo deja en caché como resultado completo. Solo
  /// reemplaza pistas en su sitio (mismo orden), así que la lista no salta.
  Future<DeezerSearchResult> enrichSearchResult(
    DeezerSearchResult raw,
    String query, {
    DeezerSearchType type = DeezerSearchType.all,
  }) async {
    final cacheKey = '${type.name}:${query.trim()}';
    final cached = _searchCache.get(cacheKey);
    if (cached != null) return cached;
    // Primero la versión del propio artista (la de una recopilación cambia
    // de portada y álbum, ver `CanonicalVersionResolver`), después los
    // colaboradores de lo que quedó.
    final canonical = await canonicalResolver.resolveTop(raw.tracks);
    final tracks = await _enrichAmbiguousTitles(canonical);
    final result = DeezerSearchResult(tracks: tracks, artists: raw.artists, albums: raw.albums);
    _searchCache.put(cacheKey, result);
    return result;
  }

  /// Playlists ya hechas de Deezer (`/search/playlist`, ronda 5): para
  /// encontrar, por ejemplo, una playlist para una fiesta. Las de los
  /// editores de Deezer van primero y las vacías o diminutas se descartan.
  Future<List<DeezerPlaylist>> searchPlaylists(String query, {int limit = 50}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    return _rateLimiter.run(() async {
      final response = await _dio.get('/search/playlist', queryParameters: {'q': trimmed, 'limit': limit});
      final data = response.data;
      if (data == null || data is! Map || data['data'] is! List) return const <DeezerPlaylist>[];
      final list = [
        for (final item in data['data'] as List)
          if (item is Map) DeezerPlaylist.fromJson(Map<String, dynamic>.from(item)),
      ].where((p) => p.nbTracks >= 5).toList();
      bool isEditorial(DeezerPlaylist p) => p.userName.toLowerCase().contains('deezer');
      // Estable: dentro de cada grupo se respeta el orden de relevancia de Deezer.
      return [...list.where(isEditorial), ...list.where((p) => !isEditorial(p))];
    });
  }

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

  /// Pista por ISRC (`/track/isrc:{isrc}`), o `null` si Deezer no la tiene:
  /// responde 200 con `{"error": {"code": 800}}`. Ojo: puede devolver la
  /// entrada de una recopilación (ver `docs/fuentes_youtube_y_matching.md`),
  /// por eso la importación solo la usa como último recurso.
  Future<DeezerTrack?> getTrackByIsrc(String isrc) async {
    final code = isrc.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9]{12}$').hasMatch(code)) return null;
    return _rateLimiter.run(() async {
      final response = await _dio.get('/track/isrc:$code');
      final data = Map<String, dynamic>.from(response.data as Map);
      if (data['error'] != null) return null;
      return DeezerTrack.fromJson(data);
    });
  }

  /// Versión del propio artista en vez de la de una recopilación (ver
  /// [CanonicalVersionResolver]). Una instancia por API para compartir cachés
  /// entre el buscador y el matcher de importación/IA.
  late final CanonicalVersionResolver canonicalResolver = CanonicalVersionResolver(
    artistAlbums: (id) => getArtistAlbums(id),
    albumTracks: getAlbumTrackList,
  );

  /// Tracklist de un álbum con ISRC (`/album/{id}/tracks`; `/album/{id}` no
  /// lo trae). Los items no traen el objeto `album`: quien los usa lo
  /// completa.
  Future<List<DeezerTrack>> getAlbumTrackList(int id) async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/album/$id/tracks', queryParameters: {'limit': 300});
      final data = response.data;
      if (data is! Map || data['data'] is! List) return const <DeezerTrack>[];
      return [
        for (final item in data['data'] as List)
          if (item is Map) DeezerTrack.fromJson(Map<String, dynamic>.from(item)),
      ];
    });
  }

  /// Lanza [DeezerNotFoundException] si Deezer retiró el álbum: responde 200
  /// con `{"error": {"code": 800, ...}}` en vez de un 404, y parsearlo como
  /// álbum daba "Álbum Sin Título" sin canciones ni portada.
  Future<DeezerAlbum> getAlbum(int id) async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/album/$id');
      final data = Map<String, dynamic>.from(response.data as Map);
      if (data['error'] != null) throw DeezerNotFoundException('/album/$id');
      return DeezerAlbum.fromJson(data);
    });
  }

  Future<DeezerArtist> getArtist(int id) async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/artist/$id');
      return DeezerArtist.fromJson(Map<String, dynamic>.from(response.data as Map));
    });
  }

  /// Canciones más escuchadas de un artista (`/artist/{id}/top`).
  ///
  /// ⚠️ **Sin `limit` explícito, Deezer devuelve 5 resultados, no 10**
  /// (confirmado contra la API en vivo; ver también
  /// [getArtistTopTracksExpanded]). Por eso [limit] tiene un default propio
  /// en vez de dejar que decida el servidor.
  ///
  /// Ronda 3 (F2): la pantalla de artista pide 10 de una sola vez y muestra
  /// 5, revelando el resto con "Mostrar más" sin una segunda petición.
  ///
  /// La caché se indexa por `(id, limit)`: una llamada con límite bajo no
  /// debe dejar en caché una lista corta que luego se devuelva a quien pidió
  /// más (mismo motivo por el que [getArtistTopTracksExpanded] no comparte
  /// caché con este método).
  Future<List<DeezerTrack>> getArtistTopTracks(int id, {int limit = 10}) async {
    final cacheKey = '$id:$limit';
    final cached = _topTracksCache.get(cacheKey);
    if (cached != null) return cached;

    final top = await _rateLimiter.run(() async {
      final response = await _dio.get('/artist/$id/top', queryParameters: {'limit': limit});
      if (response.data == null || response.data['data'] is! List) return <DeezerTrack>[];
      final list = response.data['data'] as List;
      final tracks = list
          .where((item) => (item['duration'] as int? ?? 0) > 60 && item['type'] != 'podcast')
          .map((item) => DeezerTrack.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();
      tracks.sort((a, b) => (b.rank ?? 0).compareTo(a.rank ?? 0));
      return tracks;
    });
    // Ronda 5 (H-R5-6): `/artist/{id}/top` llegó a devolver `{"data":[]}`
    // para todos los artistas (2026-10-03). Sin respaldo, "Populares" quedaba
    // vacío; se arma con el `rank` de las canciones de su discografía.
    final tracks = top.isNotEmpty ? top : (await getArtistEssentials(id, limit: limit));
    _topTracksCache.put(cacheKey, tracks);
    return tracks;
  }

  final Map<String, List<DeezerTrack>> _essentialsCache = {};

  /// "Esto es {artista}" (ronda 5): sus canciones más escuchadas, solo de él,
  /// hasta [limit].
  ///
  /// Se arma con su discografía y no con `/artist/{id}/top`, que tiene dos
  /// problemas: llegó a devolver vacío para todos los artistas (H-R5-6) y
  /// mezcla canciones donde solo colabora. Se toman sus lanzamientos con más
  /// seguidores (sin recopilaciones), las canciones donde él es el artista
  /// principal, una versión por título (la más escuchada) y se ordenan por
  /// `rank`. Si `/top` responde, sus canciones propias van primero: es el
  /// orden de popularidad real de Deezer.
  Future<List<DeezerTrack>> getArtistEssentials(int id, {int limit = 100}) async {
    final cacheKey = '$id:$limit';
    final cached = _essentialsCache[cacheKey];
    if (cached != null) return cached;

    final albumsJson = await _rateLimiter.run(() async {
      final response = await _dio.get('/artist/$id/albums', queryParameters: {'limit': 150});
      final data = response.data;
      if (data == null || data['data'] is! List) return const <Map<String, dynamic>>[];
      return [for (final a in data['data'] as List) Map<String, dynamic>.from(a as Map)];
    });
    final releases = albumsJson.where((a) => a['record_type'] != 'compile').toList()
      ..sort((a, b) => ((b['fans'] as num?) ?? 0).compareTo((a['fans'] as num?) ?? 0));
    final picked = releases.take(14).toList();

    final byTitle = <String, DeezerTrack>{};
    void consider(DeezerTrack t) {
      if (t.artistId != id || t.durationSec <= 60) return;
      final key = t.title
          .toLowerCase()
          .replaceAll(RegExp(r'\s*[\(\[][^\)\]]*[\)\]]'), '')
          .replaceAll(RegExp(r'\s+-\s+.*$'), '')
          .trim();
      final existing = byTitle[key];
      if (existing == null || (t.rank ?? 0) > (existing.rank ?? 0)) byTitle[key] = t;
    }

    for (var i = 0; i < picked.length; i += 4) {
      final chunk = picked.skip(i).take(4);
      final results = await Future.wait(chunk.map((album) => _rateLimiter.run(() async {
            try {
              final response = await _dio.get('/album/${album['id']}/tracks', queryParameters: {'limit': 100});
              final data = response.data;
              if (data == null || data['data'] is! List) return const <DeezerTrack>[];
              return [
                for (final raw in data['data'] as List)
                  if ((raw as Map)['readable'] != false)
                    DeezerTrack.fromJson({
                      ...Map<String, dynamic>.from(raw),
                      // `/album/{id}/tracks` no trae el álbum en cada pista.
                      'album': {
                        'id': album['id'],
                        'title': album['title'],
                        'cover_medium': album['cover_medium'],
                      },
                    }),
              ];
            } catch (_) {
              return const <DeezerTrack>[];
            }
          })));
      for (final list in results) {
        list.forEach(consider);
      }
    }

    final fromAlbums = byTitle.values.toList()..sort((a, b) => (b.rank ?? 0).compareTo(a.rank ?? 0));
    var result = fromAlbums;
    try {
      final top = await getArtistTopTracksExpanded(id, limit: 100);
      final own = top.where((t) => t.artistId == id).toList();
      if (own.isNotEmpty) {
        final seen = own.map((t) => t.id).toSet();
        final seenTitles = own.map((t) => t.title.toLowerCase()).toSet();
        result = [
          ...own,
          ...fromAlbums.where((t) => !seen.contains(t.id) && !seenTitles.contains(t.title.toLowerCase())),
        ];
      }
    } catch (_) {}
    result = result.take(limit).toList();
    if (result.isNotEmpty) _essentialsCache[cacheKey] = result;
    return result;
  }

  /// D1 (Fase D, búsqueda de colaboraciones): top tracks del artista pidiendo
  /// explícitamente un límite alto. `/artist/{id}/top` sin `limit` en la URL
  /// devuelve solo **5** resultados (confirmado contra la API en vivo) —
  /// insuficiente para encontrar una colaboración que no esté entre los 5
  /// temas más sonados del artista (ej. "Guess" de Charli xcx aparece bien
  /// más abajo en su top). No comparte caché con [getArtistTopTracks] porque
  /// el tamaño de la respuesta es distinto (evita que una llamada con límite
  /// bajo deje en caché una lista corta que luego se devuelva para una
  /// llamada que pidió más).
  Future<List<DeezerTrack>> getArtistTopTracksExpanded(int id, {int limit = 100}) async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/artist/$id/top', queryParameters: {'limit': limit});
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

  /// Discografía del artista.
  ///
  /// ⚠️ **`/artist/{id}/albums` devuelve solo 25 entradas sin `limit`
  /// explícito** (verificado contra la API en vivo: Coldplay tiene 121 y
  /// llegaban 25). Como la lista viene ordenada por fecha, esas 25 eran casi
  /// todo lanzamientos recientes — por eso el filtro de "Sencillos" mostraba
  /// dos, no las decenas que el artista tiene. No era un problema de la
  /// clasificación de Deezer: era nuestro, por no paginar.
  ///
  /// [limit] generoso a propósito: es UNA petición y cubre discografías muy
  /// largas sin tener que encadenar páginas.
  Future<List<DeezerAlbum>> getArtistAlbums(int id, {int limit = 300}) async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/artist/$id/albums', queryParameters: {'limit': limit});
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

  /// Playlists editoriales del chart general (`/chart/0/playlists`).
  ///
  /// ⚠️ **Sin `limit` explícito devuelve solo 10** (verificado contra la API en
  /// vivo, que acepta hasta 100). Esa era la razón de que la sección de Inicio
  /// se acabara tras un scroll: no se estaba mandando el parámetro.
  Future<List<DeezerPlaylist>> getEditorialPlaylists({int limit = 50}) async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/chart/0/playlists', queryParameters: {'limit': limit});
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

  /// Radio "inteligente" curada por Deezer, sembrada en el artista [artistId]
  /// (Fase 7.B, D-10: radio/cola infinita sin IA). Mismo filtro de calidad
  /// (duración/podcast) y orden por `rank` que el resto de endpoints de
  /// tracks de este archivo.
  Future<List<DeezerTrack>> getArtistRadio(int artistId) async {
    final cached = _artistRadioCache.get(artistId);
    if (cached != null) return cached;

    return _rateLimiter.run(() async {
      final response = await _dio.get('/artist/$artistId/radio');
      if (response.data == null || response.data['data'] is! List) return [];
      final list = response.data['data'] as List;
      final tracks = list
          .where((item) => (item['duration'] as int? ?? 0) > 60 && item['type'] != 'podcast')
          .map((item) => DeezerTrack.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();
      tracks.sort((a, b) => (b.rank ?? 0).compareTo(a.rank ?? 0));
      _artistRadioCache.put(artistId, tracks);
      return tracks;
    });
  }

  /// Artistas relacionados/similares al artista [artistId] (Fase 7.B).
  ///
  /// Pese al nombre, `/artist/{id}/related` de Deezer devuelve **artistas**,
  /// no pistas — verificado contra la API en vivo (agosto 2026, ver
  /// `docs/plan_fase_7.md` 7.B.1). Se usa para completar semillas de radio
  /// cuando el contexto activo tiene menos de 5 artistas distintos.
  Future<List<DeezerArtist>> getArtistRelated(int artistId) async {
    final cached = _artistRelatedCache.get(artistId);
    if (cached != null) return cached;

    return _rateLimiter.run(() async {
      final response = await _dio.get('/artist/$artistId/related');
      if (response.data == null || response.data['data'] is! List) return [];
      final list = response.data['data'] as List;
      final artists = list
          .map((item) => DeezerArtist.fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();
      _artistRelatedCache.put(artistId, artists);
      return artists;
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

  // ---------------------------------------------------------------------
  // Catálogo por género, radios editoriales y playlists (Inicio / Explorar)
  // ---------------------------------------------------------------------

  /// Usuario oficial `Deezer Charts`, dueño de las ~100 playlists "Top {país}"
  /// que Deezer mantiene al día (verificado en vivo: `Top Worldwide`,
  /// `Top Mexico`, `Top Brazil`, ... de 100 pistas cada una).
  ///
  /// Es la única forma de tener tops **por país** con esta API pública:
  /// `/chart/0` existe pero es geo-IP, sin parámetro de país.
  static const int deezerChartsUserId = 637006841;

  /// Lista de géneros del catálogo (`/genre`).
  ///
  /// Excluye el id 0 ("Todos"), que no es un género real sino el comodín que
  /// usan `/chart/0` y `/editorial/0`.
  ///
  /// Los nombres llegan **ya localizados** por región (desde México:
  /// "Reggaetón", "Música Mexicana", "Clásica"), así que no hay que traducir
  /// ni mantener listas a mano.
  Future<List<DeezerGenre>> getGenres() async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/genre');
      if (response.data == null || response.data['data'] is! List) return [];
      return (response.data['data'] as List)
          .whereType<Map>()
          .map((item) => DeezerGenre.fromJson(Map<String, dynamic>.from(item)))
          .where((g) => g.id != 0)
          .toList();
    });
  }

  /// Chart completo de un género (`/chart/{genre_id}`).
  ///
  /// Trae pistas, álbumes, artistas y playlists **en una sola petición** — es
  /// lo que alimenta la pantalla de género entera con un único request.
  Future<DeezerGenreChart> getGenreChart(int genreId, {int limit = 50}) async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/chart/$genreId', queryParameters: {'limit': limit});
      if (response.data is! Map) return const DeezerGenreChart();
      return DeezerGenreChart.fromJson(Map<String, dynamic>.from(response.data as Map));
    });
  }

  /// Radios editoriales de un género (`/genre/{id}/radios`).
  Future<List<DeezerRadio>> getGenreRadios(int genreId) async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/genre/$genreId/radios');
      if (response.data == null || response.data['data'] is! List) return [];
      return (response.data['data'] as List)
          .whereType<Map>()
          .map((item) => DeezerRadio.fromJson(Map<String, dynamic>.from(item)))
          .where((r) => r.id != 0)
          .toList();
    });
  }

  /// Pistas de una radio editorial (`/radio/{id}/tracks`).
  ///
  /// ⚠️ **No es determinista**: dos llamadas seguidas devuelven selecciones
  /// distintas (verificado contra la API en vivo). Quien la consuma tiene que
  /// tratar el resultado como una tirada, no como una lista estable — ver
  /// `mix_engine.dart`, que congela la tirada por sesión.
  Future<List<DeezerTrack>> getRadioTracks(int radioId) async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/radio/$radioId/tracks');
      if (response.data == null || response.data['data'] is! List) return [];
      return (response.data['data'] as List)
          .whereType<Map>()
          .where((item) => (item['duration'] as int? ?? 0) > 60 && item['type'] != 'podcast')
          .map((item) => DeezerTrack.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    });
  }

  /// Playlist de Deezer con todas sus pistas (`/playlist/{id}`).
  ///
  /// A diferencia de las radios, una playlist **sí** es un objeto estable: el
  /// mismo id devuelve el mismo contenido hasta que Deezer la actualiza.
  Future<DeezerPlaylist> getPlaylist(int id) async {
    return _rateLimiter.run(() async {
      final response = await _dio.get('/playlist/$id');
      return DeezerPlaylist.fromJson(Map<String, dynamic>.from(response.data as Map));
    });
  }

  /// Las playlists "Top {país}" oficiales de Deezer, en **una** petición.
  ///
  /// Filtra el ruido del listado: la "Canciones favoritas" vacía del usuario y
  /// cualquier playlist sin pistas.
  Future<List<DeezerPlaylist>> getCountryTopPlaylists() async {
    return _rateLimiter.run(() async {
      final response = await _dio.get(
        '/user/$deezerChartsUserId/playlists',
        queryParameters: {'limit': 100},
      );
      if (response.data == null || response.data['data'] is! List) return [];
      return (response.data['data'] as List)
          .whereType<Map>()
          .map((item) => DeezerPlaylist.fromJson(Map<String, dynamic>.from(item)))
          .where((p) => p.nbTracks > 0 && p.title.toLowerCase().startsWith('top '))
          .toList();
    });
  }
}
