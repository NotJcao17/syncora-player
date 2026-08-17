import '../../data/apis/deezer_api.dart';
import '../../data/models/deezer/deezer_album.dart';
import '../../data/models/deezer/deezer_track.dart';
import 'search_ranking.dart';

/// D2 (Fase D): "Buscar otras versiones" — crawl acotado de discografía,
/// siempre como acción MANUAL (dos puntos de entrada, nunca automático).
///
/// Resuelve el hueco real de índice de Deezer documentado en el plan: el
/// caso "Guess" de Charli xcx, donde la versión solista (`id: 2837358742`,
/// dentro del álbum "Brat and it's the same but there's three more songs so
/// it's not") existe en el catálogo pero no aparece bajo ninguna query de
/// `/search`, ni con sintaxis avanzada — solo alcanzable listando los tracks
/// de sus álbumes directamente.
///
/// Acotar por fecha de lanzamiento es lo que hace esto viable: un artista
/// con decenas de álbumes no se puede crawlear entero (confirmado contra la
/// API real: Charli xcx tiene 100 álbumes/singles listados). Cuesta 1
/// (lista de álbumes) + hasta [maxAlbums] peticiones (una por álbum
/// candidato, en paralelo).
class OtherVersionsSearch {
  OtherVersionsSearch._();

  /// Ordena álbumes por cercanía de fecha de lanzamiento a `referenceDate` y
  /// toma los [maxAlbums] más cercanos. Sin fecha de referencia conocida,
  /// confía en el orden que ya trae `getArtistAlbums` (más reciente primero)
  /// y toma los primeros [maxAlbums].
  static List<DeezerAlbum> nearestAlbums(
    List<DeezerAlbum> albums,
    DateTime? referenceDate, {
    int maxAlbums = 15,
  }) {
    if (referenceDate == null) return albums.take(maxAlbums).toList();

    final withDates = albums.where((a) => a.releaseDate.isNotEmpty).toList();
    withDates.sort((a, b) {
      final da = DateTime.tryParse(a.releaseDate);
      final db = DateTime.tryParse(b.releaseDate);
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return da.difference(referenceDate).abs().compareTo(db.difference(referenceDate).abs());
    });
    return withDates.take(maxAlbums).toList();
  }

  /// Filtra los tracks de una lista de álbumes ya cargados con `matches`.
  /// Deduplicado por id.
  static List<DeezerTrack> filterAlbumTracks(List<DeezerAlbum> albums, bool Function(DeezerTrack) matches) {
    final seenIds = <int>{};
    final result = <DeezerTrack>[];
    for (final album in albums) {
      for (final t in album.tracks) {
        if (matches(t) && seenIds.add(t.id)) result.add(t);
      }
    }
    return result;
  }

  /// Conveniencia sobre [filterAlbumTracks]: coincidencia por título base
  /// (`SearchRanking.baseTitle` agrupa variantes como "(feat...)" /
  /// "- Remix" / "- Live" bajo el mismo título, así "Guess" y "Guess
  /// featuring billie eilish" cuentan como la misma canción). Es el caso de
  /// uso principal — D2 entrada 1 (track_tile.dart) y el fallback desde D3.
  static List<DeezerTrack> filterMatchingTitle(List<DeezerAlbum> albums, String title) {
    final targetBase = SearchRanking.baseTitle(title);
    return filterAlbumTracks(albums, (t) => SearchRanking.baseTitle(t.title) == targetBase);
  }

  /// Crawl acotado completo: lista de álbumes del artista (1 req) -> los
  /// [maxAlbums] más cercanos en fecha a `referenceAlbumId` (si se conoce y
  /// está entre los álbumes del propio artista — gratis, no cuesta una
  /// petición aparte) -> detalle de cada álbum candidato, en paralelo ->
  /// filtro con `matches`.
  ///
  /// El criterio de filtro es un parámetro (no siempre "mismo título"): el
  /// fallback desde la pestaña "Colaboración" (D1, cuando no encuentra nada)
  /// también reusa este mismo crawl, pero busca tracks que mencionen al
  /// otro artista (`CollaborationSearch.trackHasArtist`), no un título
  /// concreto.
  static Future<List<DeezerTrack>> search(
    DeezerApi api, {
    required int artistId,
    required bool Function(DeezerTrack) matches,
    int? referenceAlbumId,
    int maxAlbums = 15,
  }) async {
    final albums = await api.getArtistAlbums(artistId);

    DateTime? referenceDate;
    if (referenceAlbumId != null) {
      for (final a in albums) {
        if (a.id == referenceAlbumId) {
          referenceDate = DateTime.tryParse(a.releaseDate);
          break;
        }
      }
    }

    final candidates = nearestAlbums(albums, referenceDate, maxAlbums: maxAlbums);
    if (candidates.isEmpty) return const [];

    final fullAlbums = await Future.wait(
      candidates.map((a) async {
        try {
          return await api.getAlbum(a.id);
        } catch (_) {
          return null;
        }
      }),
    );

    return filterAlbumTracks(fullAlbums.whereType<DeezerAlbum>().toList(), matches);
  }

  /// Conveniencia sobre [search]: filtra por título base. Uso más común (D2
  /// entrada 1 y el fallback desde D3).
  static Future<List<DeezerTrack>> searchByTitle(
    DeezerApi api, {
    required int artistId,
    required String title,
    int? referenceAlbumId,
    int maxAlbums = 15,
  }) {
    final targetBase = SearchRanking.baseTitle(title);
    return search(
      api,
      artistId: artistId,
      matches: (t) => SearchRanking.baseTitle(t.title) == targetBase,
      referenceAlbumId: referenceAlbumId,
      maxAlbums: maxAlbums,
    );
  }
}
