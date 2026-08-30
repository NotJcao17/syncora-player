import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/connectivity_service.dart';
import '../../core/utils/startup_retry.dart';
import '../../data/apis/deezer_provider.dart';
import '../../data/local_db/database_provider.dart';
import '../../data/models/deezer/deezer_album.dart';
import '../../data/models/deezer/deezer_artist.dart';
import '../../data/models/deezer/deezer_playlist.dart';
import '../../data/models/deezer/deezer_track.dart';

/// Corte de los reintentos de arranque: estando realmente sin red no se quema
/// el presupuesto entero antes de avisar, y el estado "Sin conexión" de Inicio
/// sigue apareciendo al instante.
///
/// Solo LEE `isConnectedProvider` (nunca lo modifica): ese provider tiene
/// consumidores sensibles, entre ellos el guard que gatea el relleno de la
/// cola de radio del reproductor.
bool Function() _networkStillPlausible(Ref ref) =>
    () => ref.read(isConnectedProvider).value ?? true;

class PersonalizedArtistSection {
  final DeezerArtist artist;
  final List<DeezerTrack> tracks;

  const PersonalizedArtistSection({
    required this.artist,
    required this.tracks,
  });
}

final editorialPlaylistsProvider = FutureProvider<List<DeezerPlaylist>>((ref) async {
  final deezerApi = ref.watch(deezerApiProvider);
  return retryOnNetworkError(
    deezerApi.getEditorialPlaylists,
    shouldRetry: _networkStillPlausible(ref),
  );
});

final topChartsProvider = FutureProvider<List<DeezerTrack>>((ref) async {
  final deezerApi = ref.watch(deezerApiProvider);
  return retryOnNetworkError(
    deezerApi.getTopCharts,
    shouldRetry: _networkStillPlausible(ref),
  );
});

final newReleasesProvider = FutureProvider<List<DeezerAlbum>>((ref) async {
  final deezerApi = ref.watch(deezerApiProvider);
  return retryOnNetworkError(
    deezerApi.getNewReleases,
    shouldRetry: _networkStillPlausible(ref),
  );
});

final personalizedSectionsProvider = FutureProvider<List<PersonalizedArtistSection>>((ref) async {
  final deezerApi = ref.watch(deezerApiProvider);
  final historyDao = ref.watch(listeningHistoryDaoProvider);

  List<int> topArtistIds = await historyDao.getTopArtistIds(limit: 3);

  // Fallback para instalaciones nuevas sin historial
  if (topArtistIds.isEmpty) {
    topArtistIds = [1421, 10583405, 8706544]; // Coldplay, Bad Bunny, Dua Lipa
  }

  final sections = <PersonalizedArtistSection>[];

  for (final artistId in topArtistIds) {
    try {
      final artist = await retryOnNetworkError(
        () => deezerApi.getArtist(artistId),
        shouldRetry: _networkStillPlausible(ref),
      );
      final tracks = await retryOnNetworkError(
        () => deezerApi.getArtistTopTracks(artistId),
        shouldRetry: _networkStillPlausible(ref),
      );
      if (tracks.isNotEmpty) {
        sections.add(PersonalizedArtistSection(artist: artist, tracks: tracks));
      }
    } catch (_) {}
  }

  return sections;
});
