import '../../../data/apis/deezer_api.dart';
import '../../../data/models/deezer/deezer_album.dart';
import '../../../data/models/deezer/deezer_artist.dart';
import '../../../data/models/deezer/deezer_track.dart';
import 'playlist_import_export_service.dart';

/// Resuelve una fila de un CSV/TXT (o una sugerencia de la IA) contra el
/// catálogo de Deezer (ronda 4, H-R4-13).
///
/// **Por qué se reescribió.** La cascada anterior empezaba por la sintaxis
/// avanzada `artist:"X" track:"Y"`, que Deezer **ya no resuelve** (devuelve 0
/// resultados siempre; verificado en vivo el 2026-09-25). Todo caía a la
/// búsqueda de texto plano y de ahí se elegía la pista **con la duración más
/// parecida sin mirar el artista**: una versión 8-bit, un karaoke o un cover
/// de duración casi idéntica le ganaban al original. Además, algunos
/// artistas (p. ej. Adele) no aparecen en la búsqueda de canciones de la API
/// pública, pero sus álbumes sí en la búsqueda de álbumes.
///
/// **Cómo decide ahora**, de más barato a más caro:
/// 1. Búsqueda de canciones "artista título". Solo cuentan candidatos del
///    mismo artista y con título compatible; se penalizan karaokes, covers,
///    tributos, instrumentales, y versiones en vivo/remix/acústicas que el
///    archivo no pedía. Si además coincide el álbum, listo.
/// 2. Si el archivo trae álbum y el paso 1 no dio la versión de ese álbum:
///    búsqueda de álbumes "artista álbum" y se toma la pista del tracklist.
///    Así se prefiere la versión del álbum sobre la del sencillo.
/// 3. Si el paso 1 dio una versión correcta de otro álbum, se usa esa.
/// 4. Si el artista no sale en la búsqueda de canciones: su top de
///    canciones (por el id que dio la búsqueda de álbumes o de artistas).
/// 5. Si nada coincide, la fila queda como "no encontrada": es preferible a
///    meter la canción de otro artista.
///
/// Las búsquedas de álbum y los tracklists se memorizan por instancia: una
/// playlist suele tener varias canciones del mismo álbum.
class ImportTrackMatcher {
  ImportTrackMatcher(this._api);

  final DeezerApi _api;
  final Map<String, Future<List<DeezerAlbum>>> _albumSearches = {};
  final Map<int, Future<List<DeezerTrack>>> _albumTracks = {};
  final Map<int, Future<List<DeezerTrack>>> _artistTops = {};
  final Map<String, Future<int?>> _artistIds = {};
  final Map<int, Future<List<DeezerAlbum>>> _discographies = {};

  /// Umbral mínimo de similitud de título para aceptar un candidato.
  static const double _minTitleSimilarity = 0.5;

  Future<DeezerTrack?> match(RawImportTrack raw) async {
    final artists = artistKeys(raw.artist);
    final primary = primaryArtistName(raw.artist);
    final title = raw.title.trim();
    if (title.isEmpty) return null;

    // Sin artista (TXT con solo el título): lo mejor que se puede hacer es
    // el título, evitando al menos karaokes y covers.
    if (artists.isEmpty) {
      final res = await _safeSearch(cleanQueryTitle(title), DeezerSearchType.track);
      return _best(res, raw, requireArtist: false)?.track;
    }

    final trackResults = await _safeSearch('$primary ${cleanQueryTitle(title)}', DeezerSearchType.track);
    var fromSearch = _best(trackResults, raw);
    // Sintaxis mixta `Artista track:"Título"`: la que sigue funcionando tras
    // el cambio de Deezer (el reporte de SoulSync #1295 la propone) y, a
    // diferencia del texto plano, sí devuelve artistas que Deezer esconde de
    // la búsqueda normal (Adele). Solo se gasta si la primera no bastó.
    if (fromSearch == null || !fromSearch.exactTitle) {
      final quoted = cleanQueryTitle(title).replaceAll('"', '');
      final mixed = await _safeSearch('$primary track:"$quoted"', DeezerSearchType.track);
      final alt = _best(mixed, raw);
      if (alt != null && (fromSearch == null || alt.score > fromSearch.score)) fromSearch = alt;
    }
    if (fromSearch != null && fromSearch.albumMatches && fromSearch.exactTitle) return fromSearch.track;

    final album = raw.album?.trim() ?? '';
    List<DeezerAlbum> albums = const [];
    int? artistId;
    if (album.isNotEmpty) {
      albums = await _searchAlbums(primary, album);
      final fromAlbum = await _fromAlbums(albums, raw);
      if (fromAlbum != null) return fromAlbum;

      // La búsqueda de álbumes no siempre trae el álbum (p. ej. "21" de
      // Adele no sale buscando "Adele 21"); la discografía del artista sí.
      artistId = (fromSearch != null && fromSearch.track.artistId != 0)
          ? fromSearch.track.artistId
          : await _artistIdFor(primary, albums);
      if (artistId != null) {
        final discography = await _discography(artistId, primary);
        final fromDiscography = await _fromAlbums(discography, raw);
        if (fromDiscography != null) return fromDiscography;
      }
    }

    if (fromSearch != null) return fromSearch.track;

    // El artista no aparece en la búsqueda de canciones: su top.
    artistId ??= await _artistIdFor(primary, albums);
    if (artistId == null) return null;
    final id = artistId;
    final top = await _artistTops.putIfAbsent(id, () async {
      try {
        return await _api.getArtistTopTracksExpanded(id, limit: 100);
      } catch (_) {
        return const <DeezerTrack>[];
      }
    });
    return _best(top, raw)?.track;
  }

  Future<List<DeezerTrack>> _safeSearch(String query, DeezerSearchType type) async {
    try {
      return (await _api.search(query, type: type, enrich: false)).tracks;
    } catch (_) {
      return const [];
    }
  }

  Future<List<DeezerAlbum>> _searchAlbums(String primary, String album) {
    final key = '${normalizeName(primary)}|${normalizeAlbum(album)}';
    return _albumSearches.putIfAbsent(key, () async {
      try {
        final res = await _api.search('$primary ${cleanQueryTitle(album)}', type: DeezerSearchType.album, enrich: false);
        return res.albums;
      } catch (_) {
        return const <DeezerAlbum>[];
      }
    });
  }

  Future<DeezerTrack?> _fromAlbums(List<DeezerAlbum> albums, RawImportTrack raw) async {
    final artists = artistKeys(raw.artist);
    final wanted = normalizeAlbum(raw.album ?? '');
    final candidates = albums
        .where((a) => artists.contains(normalizeName(a.artistName)))
        .where((a) => similarity(normalizeAlbum(a.title), wanted) >= 0.6)
        .toList()
      ..sort((a, b) => similarity(normalizeAlbum(b.title), wanted).compareTo(similarity(normalizeAlbum(a.title), wanted)));
    for (final a in candidates.take(2)) {
      final tracks = await _albumTracks.putIfAbsent(a.id, () async {
        try {
          return (await _api.getAlbum(a.id)).tracks;
        } catch (_) {
          return const <DeezerTrack>[];
        }
      });
      final best = _best(tracks, raw, albumOverride: a.title);
      // Dentro de un álbum solo vale el título exacto: una edición deluxe
      // puede traer además regrabaciones con sufijo ("(The Warner Sound)").
      if (best != null && best.exactTitle) return best.track;
    }
    return null;
  }

  /// Discografía del artista (cacheada). `/artist/{id}/albums` no trae el
  /// objeto `artist`, así que se completa con el que ya se conoce.
  Future<List<DeezerAlbum>> _discography(int artistId, String artistName) {
    return _discographies.putIfAbsent(artistId, () async {
      try {
        final albums = await _api.getArtistAlbums(artistId);
        return [for (final a in albums) a.withArtist(artistId: artistId, artistName: artistName)];
      } catch (_) {
        return const <DeezerAlbum>[];
      }
    });
  }

  Future<int?> _artistIdFor(String primary, List<DeezerAlbum> albums) {
    final key = normalizeName(primary);
    for (final a in albums) {
      if (normalizeName(a.artistName) == key && a.artistId != 0) return Future.value(a.artistId);
    }
    return _artistIds.putIfAbsent(key, () async {
      try {
        final res = await _api.search(primary, type: DeezerSearchType.artist, enrich: false);
        final matches = res.artists.where((DeezerArtist a) => normalizeName(a.name) == key).toList()
          ..sort((a, b) => b.nbFan.compareTo(a.nbFan));
        return matches.isEmpty ? null : matches.first.id;
      } catch (_) {
        return null;
      }
    });
  }

  ScoredCandidate? _best(List<DeezerTrack> candidates, RawImportTrack raw, {bool requireArtist = true, String? albumOverride}) {
    ScoredCandidate? best;
    for (final c in candidates) {
      final s = scoreCandidate(c, raw, requireArtist: requireArtist, albumOverride: albumOverride);
      if (s == null) continue;
      if (best == null || s.score > best.score) best = s;
    }
    return best;
  }

  // ---------------------------------------------------------------------
  // Puntuación (pública para tests)
  // ---------------------------------------------------------------------

  /// Palabras que delatan una versión que NO es el original, salvo que el
  /// propio archivo las traiga en el título. Con cualquiera de estas, el
  /// candidato se descarta.
  static const _rejectMarkers = [
    'karaoke', 'cover', 'tribute', 'tributo', 'instrumental', 'originally performed', 'originally perfomed',
    'made popular', 'made famous', 'as performed by', 'in the style of', 'emulation', '8 bit', '8bit',
    '16 bit', 'ringtone', 'lullaby', 'backing track', 'piano version', 'music box', 'sped up', 'slowed',
    'nightcore', 'reverb', 'workout', 'fitness',
  ];

  /// Variantes legítimas pero distintas: se aceptan, con penalización, si el
  /// archivo no las pedía.
  static const _variantMarkers = ['live', 'en vivo', 'remix', 'mix', 'acoustic', 'acustica', 'demo', 'edit', 'version', 'mono'];

  static ScoredCandidate? scoreCandidate(DeezerTrack c, RawImportTrack raw, {bool requireArtist = true, String? albumOverride}) {
    final artists = artistKeys(raw.artist);
    final candidateArtists = {
      normalizeName(c.artistName),
      for (final a in c.contributorsList) normalizeName(a.name),
    };
    final artistOk = artists.isNotEmpty && candidateArtists.any(artists.contains);
    if (requireArtist && !artistOk) return null;

    final rawTitle = normalizeTitle(raw.title);
    final candTitle = normalizeTitle(c.title);
    final rawSpaced = ' $rawTitle ';
    final candSpaced = ' $candTitle ';
    for (final m in _rejectMarkers) {
      if (candSpaced.contains(' $m ') && !rawSpaced.contains(' $m ')) return null;
    }

    final titleSim = [
      similarity(candTitle, rawTitle),
      similarity(baseTitle(c.title), baseTitle(raw.title)) >= 0.99 ? 0.9 : 0.0,
    ].reduce((a, b) => a > b ? a : b);
    if (titleSim < _minTitleSimilarity) return null;

    var score = titleSim;
    if (artistOk) score += 1.0;
    for (final m in _variantMarkers) {
      if (candSpaced.contains(' $m ') && !rawSpaced.contains(' $m ')) score -= 0.3;
    }
    // Palabras de más en el título del candidato ("(The Warner Sound)",
    // "(Live in Paris)"): otra grabación, aunque el título base coincida.
    final rawTokens = rawTitle.split(' ').toSet();
    final exactTitle = candTitle.split(' ').every(rawTokens.contains);
    if (!exactTitle) score -= 0.4;

    final expectedMs = raw.durationMs;
    if (expectedMs != null && expectedMs > 0 && c.durationSec > 0) {
      final diff = (c.durationSec - expectedMs / 1000).abs();
      if (diff > 30) {
        score -= 0.6;
      } else {
        score += (1 - diff / 30) * 0.3;
      }
    }

    var albumMatches = false;
    final wantedAlbum = normalizeAlbum(raw.album ?? '');
    if (wantedAlbum.isNotEmpty) {
      final candAlbum = normalizeAlbum(albumOverride ?? c.albumTitle);
      if (candAlbum.isNotEmpty && similarity(candAlbum, wantedAlbum) >= 0.8) {
        albumMatches = true;
        score += 0.4;
      }
    }

    // Desempate por popularidad: a igualdad, la versión más escuchada.
    score += ((c.rank ?? 0) / 1000000).clamp(0, 1) * 0.05;
    return ScoredCandidate(c, score, albumMatches, exactTitle);
  }

  // ---------------------------------------------------------------------
  // Normalización
  // ---------------------------------------------------------------------

  static const _accents = {
    'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ã': 'a', 'å': 'a',
    'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
    'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i',
    'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', 'õ': 'o', 'ø': 'o',
    'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
    'ñ': 'n', 'ç': 'c', 'ß': 'ss',
  };

  static String _fold(String s) {
    var out = s.toLowerCase();
    _accents.forEach((k, v) => out = out.replaceAll(k, v));
    return out.replaceAll('&', ' and ').replaceAll("'", '').replaceAll('’', '');
  }

  static String _words(String s) =>
      s.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  static final _featClause = RegExp(r'[\(\[]\s*(feat\.?|ft\.?|featuring|with|con)\s[^\)\]]*[\)\]]');
  static final _featTail = RegExp(r'\s(feat\.?|ft\.?|featuring)\s.*$');
  static final _remaster = RegExp(r'\b(\d{4}\s)?remaster(ed)?(\s\d{4})?(\sversion)?\b');

  /// Título comparable: sin acentos, sin "feat.", sin "Remastered 2011", con
  /// los paréntesis y guiones reducidos a palabras (Spotify escribe
  /// "X - Live", Deezer "X (Live)").
  static String normalizeTitle(String title) {
    var t = _fold(title);
    t = t.replaceAll(_featClause, ' ').replaceAll(_featTail, ' ');
    t = _words(t);
    t = t.replaceAll(_remaster, ' ');
    return _words(t);
  }

  /// Título sin nada entre paréntesis ni tras " - ".
  static String baseTitle(String title) {
    var t = _fold(title);
    t = t.replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ');
    final dash = t.indexOf(' - ');
    if (dash > 0) t = t.substring(0, dash);
    return _words(t);
  }

  static String normalizeAlbum(String album) {
    var a = _words(_fold(album).replaceAll(_featClause, ' '));
    a = a.replaceAll(
      RegExp(r'\b(deluxe|expanded|edition|version|remaster(ed)?|anniversary|special|bonus track(s)?|super|\d+th)\b'),
      ' ',
    );
    return _words(a);
  }

  /// Nombre de artista comparable ("The Weeknd" = "Weeknd", sin acentos).
  static String normalizeName(String name) {
    var n = _words(_fold(name));
    if (n.startsWith('the ')) n = n.substring(4);
    return n;
  }

  /// Separadores de colaboradores: ";" (Spotify/Exportify), "," (otros
  /// exportadores y la IA), "&", "feat.", "x", "y", "with".
  static final _artistSplit = RegExp(
    r'\s*(?:;|,|&|\bfeat\.?|\bft\.?|\bfeaturing\b|\bwith\b|\sx\s|\sy\s|\sand\s)\s*',
    caseSensitive: false,
  );

  /// Artistas de la fila: el nombre completo y cada colaborador por separado.
  ///
  /// Ronda 4: antes solo se partía por ";", así que "Rihanna, Calvin Harris"
  /// (formato de la IA y de algunos exportadores) no coincidía con nadie y la
  /// fila quedaba "no encontrada" — el 1-2 fallos constantes por importación.
  /// El nombre completo se conserva para dúos con separador en el nombre
  /// ("Jesse & Joy", "Wisin y Yandel", "Tyler, The Creator").
  static Set<String> artistKeys(String artist) {
    final keys = <String>{normalizeName(artist)};
    for (final part in artist.split(_artistSplit)) {
      if (part.trim().isNotEmpty) keys.add(normalizeName(part));
    }
    return keys..remove('');
  }

  /// Artista principal para la consulta: el primero antes de ";" o ",".
  static String primaryArtistName(String artist) => artist.split(RegExp(r'[;,]')).first.trim();

  /// Título apto para la consulta: sin "feat." (Deezer indexa sin él).
  static String cleanQueryTitle(String title) =>
      title.replaceAll(RegExp(r'\s*[\(\[]?\s*-?\s*(feat\.?|featuring|ft\.?|with)\s+.*$', caseSensitive: false), '').trim();

  /// Jaccard de palabras, con contención completa contada como 0.85.
  static double similarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    final ta = a.split(' ').toSet();
    final tb = b.split(' ').toSet();
    final inter = ta.intersection(tb).length;
    final jaccard = inter / ta.union(tb).length;
    final contained = inter == ta.length || inter == tb.length;
    return contained && jaccard < 0.85 ? (jaccard + 0.85) / 2 : jaccard;
  }
}

/// Candidato puntuado por [ImportTrackMatcher.scoreCandidate].
class ScoredCandidate {
  const ScoredCandidate(this.track, this.score, this.albumMatches, this.exactTitle);
  final DeezerTrack track;
  final double score;
  final bool albumMatches;

  /// El título del candidato no añade palabras al de la fila.
  final bool exactTitle;
}
