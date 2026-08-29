import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/startup_retry.dart';
import '../../data/apis/deezer_provider.dart';
import '../../data/local_db/database_provider.dart';
import '../../data/models/deezer/deezer_album.dart';
import '../../data/models/deezer/deezer_artist.dart';
import '../../data/models/deezer/deezer_playlist.dart';
import '../../data/models/deezer/deezer_track.dart';

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
  return retryOnNetworkError(deezerApi.getEditorialPlaylists);
});

final topChartsProvider = FutureProvider<List<DeezerTrack>>((ref) async {
  final deezerApi = ref.watch(deezerApiProvider);
  return retryOnNetworkError(deezerApi.getTopCharts);
});

final newReleasesProvider = FutureProvider<List<DeezerAlbum>>((ref) async {
  final deezerApi = ref.watch(deezerApiProvider);
  return retryOnNetworkError(deezerApi.getNewReleases);
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
      final artist = await retryOnNetworkError(() => deezerApi.getArtist(artistId));
      final tracks = await retryOnNetworkError(() => deezerApi.getArtistTopTracks(artistId));
      if (tracks.isNotEmpty) {
        sections.add(PersonalizedArtistSection(artist: artist, tracks: tracks));
      }
    } catch (_) {}
  }

  return sections;
});
