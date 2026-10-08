import 'dart:collection';

import '../models/deezer/deezer_album.dart';
import '../models/deezer/deezer_track.dart';

/// Cambia una pista que Deezer cuelga de una recopilación por la misma
/// grabación en un lanzamiento del propio artista (2026-10-08).
///
/// **El problema.** Buscar "hips don't lie" devuelve la versión de "Filtr
/// presents R&B Party" (Varios Artistas), con su portada; la de *Oral
/// Fixation, Vol. 2* existe en Deezer con el **mismo ISRC**, pero `/search`
/// ni siquiera la incluye entre los 100 primeros. Lo mismo pasa con muchos
/// éxitos: la entrada "principal" de Deezer es la de una recopilación.
///
/// **Cómo se detecta, barato.** El resultado de `/search` trae el ISRC pero
/// no el artista del álbum. En vez de pedir `/album/{id}` por pista, se mira
/// si el álbum está en la discografía del artista (`/artist/{id}/albums`,
/// una petición por artista y en caché): si no está, es de otro (una
/// recopilación, o la colaboración en el disco de otro artista).
///
/// **Cómo se corrige, sin inventar.** Se revisan como mucho
/// [maxAlbumLookups] tracklists de su discografía (`/album/{id}/tracks`, que
/// sí trae ISRC), primero los del año del ISRC, y solo se cambia la pista si
/// aparece **el mismo ISRC**. Si no aparece (p. ej. "Waka Waka" en inglés,
/// que en Deezer solo está en recopilaciones), se queda la original.
class CanonicalVersionResolver {
  CanonicalVersionResolver({required this.artistAlbums, required this.albumTracks});

  /// Discografía del artista (`/artist/{id}/albums`).
  final Future<List<DeezerAlbum>> Function(int artistId) artistAlbums;

  /// Tracklist con ISRC (`/album/{id}/tracks`).
  final Future<List<DeezerTrack>> Function(int albumId) albumTracks;

  static const int maxAlbumLookups = 4;

  final _discographies = _BoundedCache<int, Future<List<DeezerAlbum>>>(60);
  final _tracklists = _BoundedCache<int, Future<List<DeezerTrack>>>(150);
  final _resolved = _BoundedCache<int, Future<DeezerTrack>>(400);

  /// La versión del artista de [track], o [track] tal cual. Nunca lanza.
  Future<DeezerTrack> resolve(DeezerTrack track) {
    return _resolved.putIfAbsent(track.id, () async {
      try {
        return await _resolve(track);
      } catch (_) {
        // Un fallo de red no se recuerda: la próxima vez se reintenta.
        _resolved.remove(track.id);
        _discographies.remove(track.artistId);
        return track;
      }
    });
  }

  /// Resuelve los primeros [limit] de [tracks] en paralelo, en su sitio, y
  /// quita los duplicados que eso genere (la versión original podía estar ya
  /// más abajo en la lista).
  Future<List<DeezerTrack>> resolveTop(List<DeezerTrack> tracks, {int limit = 8}) async {
    if (tracks.isEmpty) return tracks;
    final head = tracks.take(limit).toList();
    final resolved = await Future.wait(head.map(resolve));
    if (!resolved.asMap().entries.any((e) => !identical(e.value, head[e.key]))) return tracks;
    final seen = <int>{};
    return [
      for (final t in [...resolved, ...tracks.skip(limit)])
        if (seen.add(t.id)) t,
    ];
  }

  Future<DeezerTrack> _resolve(DeezerTrack track) async {
    final isrc = normalizeIsrc(track.isrc);
    if (isrc == null || track.artistId == 0 || track.albumId == 0) return track;

    final albums = await _discographies.putIfAbsent(track.artistId, () => artistAlbums(track.artistId));
    if (albums.isEmpty || albums.any((a) => a.id == track.albumId)) return track;

    final candidates = orderCandidateAlbums(albums, isrc, excludeAlbumId: track.albumId);
    for (final album in candidates.take(maxAlbumLookups)) {
      final List<DeezerTrack> tracks;
      try {
        tracks = await _tracklists.putIfAbsent(album.id, () => albumTracks(album.id));
      } catch (_) {
        _tracklists.remove(album.id);
        continue;
      }
      for (final c in tracks) {
        if (normalizeIsrc(c.isrc) == isrc) return _rebuilt(track, c, album);
      }
    }
    return track;
  }

  /// La pista del álbum del artista, con la portada y el álbum de ese
  /// lanzamiento. Los artistas se conservan del original (misma grabación;
  /// los tracklists de álbum no traen colaboradores).
  static DeezerTrack _rebuilt(DeezerTrack original, DeezerTrack found, DeezerAlbum album) {
    return DeezerTrack(
      id: found.id,
      title: found.title,
      artistName: original.artistName,
      artistId: original.artistId,
      albumTitle: album.title,
      albumId: album.id,
      coverUrl: album.coverUrl.isNotEmpty ? album.coverUrl : original.coverUrl,
      durationSec: found.durationSec > 0 ? found.durationSec : original.durationSec,
      previewUrl: found.previewUrl ?? original.previewUrl,
      contributorsList: original.contributorsList,
      rank: original.rank,
      isrc: found.isrc ?? original.isrc,
    );
  }

  /// ISRC en mayúsculas, o `null` si no tiene la forma de uno (12 caracteres).
  static String? normalizeIsrc(String? raw) {
    final code = raw?.trim().toUpperCase() ?? '';
    return RegExp(r'^[A-Z0-9]{12}$').hasMatch(code) ? code : null;
  }

  /// Año de registro del ISRC (caracteres 6-7: "USSM1**06**00677" → 2006).
  static int? isrcYear(String isrc) {
    final yy = int.tryParse(isrc.substring(5, 7));
    if (yy == null) return null;
    return yy >= 40 ? 1900 + yy : 2000 + yy;
  }

  /// Orden de búsqueda en la discografía: primero los lanzamientos cercanos
  /// al año del ISRC (un año antes a dos después), después álbum > EP >
  /// sencillo, y a igualdad el más antiguo (el lanzamiento original antes
  /// que una reedición).
  static List<DeezerAlbum> orderCandidateAlbums(List<DeezerAlbum> albums, String isrc, {required int excludeAlbumId}) {
    final year = isrcYear(isrc);
    int windowRank(DeezerAlbum a) {
      final y = a.releaseDate.length >= 4 ? int.tryParse(a.releaseDate.substring(0, 4)) : null;
      if (year == null || y == null) return 1;
      return (y >= year - 1 && y <= year + 2) ? 0 : 1;
    }

    int typeRank(DeezerAlbum a) => switch (a.recordType) {
          'ep' => 1,
          'single' => 2,
          'compile' || 'compilation' => 3,
          _ => 0,
        };

    final list = albums.where((a) => a.id != excludeAlbumId).toList()
      ..sort((a, b) {
        final w = windowRank(a).compareTo(windowRank(b));
        if (w != 0) return w;
        final t = typeRank(a).compareTo(typeRank(b));
        if (t != 0) return t;
        if (a.releaseDate.isEmpty) return 1;
        if (b.releaseDate.isEmpty) return -1;
        return a.releaseDate.compareTo(b.releaseDate);
      });
    return list;
  }
}

/// Mapa con tope de entradas: descarta la más antigua al llenarse.
class _BoundedCache<K, V> {
  _BoundedCache(this.maxSize);

  final int maxSize;
  final LinkedHashMap<K, V> _map = LinkedHashMap<K, V>();

  V putIfAbsent(K key, V Function() create) {
    final existing = _map[key];
    if (existing != null) return existing;
    if (_map.length >= maxSize) _map.remove(_map.keys.first);
    return _map[key] = create();
  }

  void remove(K key) => _map.remove(key);
}
