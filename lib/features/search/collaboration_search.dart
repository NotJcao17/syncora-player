import '../../data/apis/deezer_api.dart';
import '../../data/models/deezer/deezer_artist.dart';
import '../../data/models/deezer/deezer_track.dart';
import 'search_ranking.dart';

/// Resultado de [CollaborationSearch.search]: los dos artistas resueltos (si
/// se encontraron) y las colaboraciones detectadas, ya rankeadas.
class CollaborationSearchResult {
  final DeezerArtist? artist1;
  final DeezerArtist? artist2;
  final List<DeezerTrack> tracks;

  const CollaborationSearchResult({this.artist1, this.artist2, this.tracks = const []});
}

/// D1 (Fase D): búsqueda de colaboraciones entre 2 artistas.
///
/// Reemplaza el diseño viejo (~10 peticiones secuenciales: 2 artistas, top
/// tracks de cada uno, y hasta 5 álbumes completos por artista) por uno de
/// **5 peticiones en 2 tandas paralelas**:
///   1. Resolver ambos artistas en paralelo (2 req).
///   2. En paralelo: texto plano "Artista1 Artista2" + top tracks de cada
///      artista con límite alto (3 req).
///   3. Filtrar por `contributors` cruzando ambos nombres, sin duplicados.
///
/// Sin crawl de discografía por defecto — para eso está D2 ("buscar más a
/// fondo"), ofrecido como escape manual si esto no encuentra nada.
///
/// Ver docs/plan_buscador_importacion_matcher.md, sección "Fase D".
class CollaborationSearch {
  CollaborationSearch._();

  /// Un track "tiene" a un artista si alguno de sus `contributors` coincide
  /// por id (la señal más confiable — `getArtistTopTracksExpanded` sí trae
  /// `contributors` completo) o, a falta de eso (la búsqueda de texto plano
  /// de `/search` no trae `contributors`), si el nombre del artista aparece
  /// en el artista principal, en algún contribuidor ya conocido, o en el
  /// título (cubre casos como "Guess featuring billie eilish", donde el
  /// segundo artista solo es visible en el texto del título).
  static bool trackHasArtist(DeezerTrack track, {required String artistName, int artistId = 0}) {
    if (artistId != 0 && track.contributorsList.any((c) => c.id == artistId)) return true;

    final normTarget = SearchRanking.normalize(artistName);
    if (normTarget.isEmpty) return false;

    if (SearchRanking.normalize(track.artistName).contains(normTarget)) return true;
    if (track.contributorsList.any((c) => SearchRanking.normalize(c.name).contains(normTarget))) return true;
    if (SearchRanking.normalize(track.title).contains(normTarget)) return true;
    return false;
  }

  /// Filtra `tracks` a los que tienen a AMBOS artistas — la colaboración
  /// real, no la versión solista de ninguno de los dos.
  static List<DeezerTrack> filterCollaborations(
    List<DeezerTrack> tracks, {
    required String artist1Name,
    required int artist1Id,
    required String artist2Name,
    required int artist2Id,
  }) {
    return tracks
        .where((t) =>
            trackHasArtist(t, artistName: artist1Name, artistId: artist1Id) &&
            trackHasArtist(t, artistName: artist2Name, artistId: artist2Id))
        .toList();
  }

  static Future<CollaborationSearchResult> search(
    DeezerApi api, {
    required String artist1,
    required String artist2,
  }) async {
    final a1 = artist1.trim();
    final a2 = artist2.trim();
    if (a1.isEmpty || a2.isEmpty) return const CollaborationSearchResult();

    // Tanda 1: resolver ambos artistas en paralelo (2 req). Ambas llamadas
    // arrancan antes del primer `await`, así que corren concurrentes.
    final artist1Future = api.search(a1, type: DeezerSearchType.artist);
    final artist2Future = api.search(a2, type: DeezerSearchType.artist);
    final artist1Res = await artist1Future;
    final artist2Res = await artist2Future;

    final artist1Match = artist1Res.artists.isNotEmpty ? artist1Res.artists.first : null;
    final artist2Match = artist2Res.artists.isNotEmpty ? artist2Res.artists.first : null;
    if (artist1Match == null || artist2Match == null) {
      return CollaborationSearchResult(artist1: artist1Match, artist2: artist2Match);
    }

    // Tanda 2: en paralelo, texto plano + top tracks de cada artista (3 req).
    final plainFuture = api.search('$a1 $a2', type: DeezerSearchType.track);
    final top1Future = api.getArtistTopTracksExpanded(artist1Match.id);
    final top2Future = api.getArtistTopTracksExpanded(artist2Match.id);
    final plainRes = await plainFuture;
    final top1 = await top1Future;
    final top2 = await top2Future;

    final seenIds = <int>{};
    final pool = <DeezerTrack>[];
    for (final t in [...plainRes.tracks, ...top1, ...top2]) {
      if (seenIds.add(t.id)) pool.add(t);
    }

    final matches = filterCollaborations(
      pool,
      artist1Name: a1,
      artist1Id: artist1Match.id,
      artist2Name: a2,
      artist2Id: artist2Match.id,
    );

    final ranked = SearchRanking.rankTracks(matches, '$a1 $a2');
    return CollaborationSearchResult(artist1: artist1Match, artist2: artist2Match, tracks: ranked);
  }
}
