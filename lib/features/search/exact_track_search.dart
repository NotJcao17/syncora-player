import '../../data/apis/deezer_api.dart';
import '../../data/models/deezer/deezer_track.dart';

/// Cascada de búsqueda exacta artista+título — extraída de
/// `PlaylistImportExportService` (Fase B) a un módulo compartido en Fase D
/// para que el importador CSV y la pestaña "Exacta" de Búsqueda Profunda
/// (D3) no mantengan dos copias que puedan divergir con el tiempo.
///
/// Ver docs/plan_buscador_importacion_matcher.md, decisión 5 y sección
/// "Fase D — Búsqueda profunda".
///
/// Tres intentos, de más preciso a más laxo:
///   1. Sintaxis avanzada `artist:"X" track:"Y"` — precisa pero frágil ante
///      typos/variantes de escritura.
///   2. Texto plano `"X Y"`.
///   3. Solo título — último recurso, siempre se devuelve tal cual.
///
/// Cada llamador decide, vía [ExactTrackSearch.cascadeSearch]'s parámetro
/// `accept`, cuándo un tier cuenta como "suficiente" para no seguir
/// gastando peticiones: el importador exige coincidencia de duración
/// (auto-selección desatendida, sin humano mirando); D3 no conoce la
/// duración esperada y acepta cualquier resultado no vacío (el usuario
/// elige a mano de la lista). El último tier siempre se devuelve tal cual,
/// sin pasar por `accept` — no hay ningún tier más al que caer.
class ExactTrackSearch {
  ExactTrackSearch._();

  // B5: quitar sufijos "(feat. X)" / "featuring X" / "ft. X" / "with X" del
  // título antes de construir la query — validado en el análisis original:
  // es lo que hizo funcionar "Conqueror" de AURORA (el CSV trae el feat en
  // el título, Deezer indexa la versión sin él bajo sintaxis avanzada).
  static final RegExp _featSuffix = RegExp(
    r'\s*[\(\[]?\s*-?\s*(feat\.?|featuring|ft\.?|with)\s+.*$',
    caseSensitive: false,
  );

  static String queryTitle(String title) => title.replaceAll(_featSuffix, '').trim();

  // B4: Spotify separa colaboradores con ";" (ej. "Gente De
  // Zona;Marc Anthony"). El primero se usa como artista principal en la
  // query avanzada.
  static String primaryArtist(String artist) => artist.isEmpty ? '' : artist.split(';').first.trim();

  // La sintaxis avanzada de Deezer usa comillas como delimitador de campo;
  // quitarlas del valor evita romper la query si el título/artista ya trae
  // comillas literales.
  static String forQuery(String s) => s.replaceAll('"', '').trim();

  /// Mejor candidato por cercanía de duración (decisión 6 del plan: nunca
  /// coincidencia exacta, siempre tolerancia). Sin duración esperada, se
  /// confía en el primero (ya viene rankeado por relevancia). Con duración
  /// esperada, se exige estar dentro de [toleranceSec] para no quedarse con
  /// una versión Live/Acústica/Remix que matchea el texto pero no la
  /// duración.
  static DeezerTrack? bestByDuration(List<DeezerTrack> tracks, int? expectedMs, {required int toleranceSec}) {
    if (tracks.isEmpty) return null;
    if (expectedMs == null) return tracks.first;

    DeezerTrack? best;
    int bestDiff = 1 << 30;
    final expectedSec = (expectedMs / 1000).round();
    for (final t in tracks) {
      final diff = (t.durationSec - expectedSec).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = t;
      }
    }
    return (best != null && bestDiff <= toleranceSec) ? best : null;
  }

  /// Corre la cascada de 3 tiers. Devuelve los tracks del primer tier que
  /// `accept` aprueba (la lista completa de esa respuesta, sin filtrar) o,
  /// si ningún tier intermedio fue aceptado, los del último tier tal cual
  /// (posiblemente vacíos) — es el último recurso, no hay mejor alternativa
  /// a la que caer.
  static Future<List<DeezerTrack>> cascadeSearch(
    DeezerApi api, {
    required String artist,
    required String title,
    required bool Function(List<DeezerTrack> tracks) accept,
  }) async {
    final qTitle = queryTitle(title);
    final pArtist = primaryArtist(artist);

    if (pArtist.isNotEmpty && qTitle.isNotEmpty) {
      try {
        final advanced = 'artist:"${forQuery(pArtist)}" track:"${forQuery(qTitle)}"';
        final res = await api.search(advanced, type: DeezerSearchType.track);
        if (accept(res.tracks)) return res.tracks;
      } catch (_) {}
    }

    try {
      final plain = pArtist.isNotEmpty ? '$pArtist $qTitle' : qTitle;
      final res = await api.search(plain, type: DeezerSearchType.track);
      if (accept(res.tracks)) return res.tracks;
    } catch (_) {}

    try {
      final res = await api.search(qTitle, type: DeezerSearchType.track);
      return res.tracks;
    } catch (_) {
      return const [];
    }
  }
}
