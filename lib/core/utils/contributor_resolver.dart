import '../../data/apis/deezer_api.dart';
import '../../data/models/deezer/deezer_track.dart';
import '../../features/player/player_models.dart';

/// `/search` de Deezer no incluye el array `contributors` (solo el artista principal);
/// únicamente `/track/{id}` y `/artist/{id}/top` lo traen. Estas funciones piden el
/// detalle completo de una pista, pero solo en el momento de persistirla (agregar a
/// playlist, dar like, descargar) — nunca mientras se navegan resultados de búsqueda.
///
/// Si la pista ya trae más de un colaborador (p. ej. vino de `getArtistTopTracks`),
/// no se hace ninguna petición extra.

Future<List<SyncoraArtistRef>> resolveTrackContributors(
  DeezerApi deezerApi,
  SyncoraTrack track,
) async {
  if (track.artists.length > 1) return track.artists;

  final deezerId = int.tryParse(track.id);
  if (deezerId == null) return track.artists;

  try {
    final full = await deezerApi.getTrack(deezerId);
    if (full.contributorsList.length > 1) return full.contributorsList;
  } catch (_) {}

  return track.artists;
}

Future<List<SyncoraArtistRef>> resolveDeezerTrackContributors(
  DeezerApi deezerApi,
  DeezerTrack track,
) async {
  if (track.contributorsList.length > 1) return track.contributorsList;

  try {
    final full = await deezerApi.getTrack(track.id);
    if (full.contributorsList.length > 1) return full.contributorsList;
  } catch (_) {}

  return track.contributorsList;
}
