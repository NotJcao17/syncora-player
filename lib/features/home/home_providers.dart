import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/cache/api_cache.dart';
import '../../core/utils/connectivity_service.dart';
import '../../core/utils/startup_retry.dart';
import '../../data/apis/deezer_catalog_providers.dart';
import '../../data/apis/deezer_provider.dart';
import '../../data/local_db/database_provider.dart';
import '../../data/models/deezer/deezer_album.dart';
import '../../data/models/deezer/deezer_artist.dart';
import '../../data/models/deezer/deezer_playlist.dart';
import 'mixes/mix_engine.dart';

/// Corte de los reintentos de arranque: estando realmente sin red no se quema
/// el presupuesto entero antes de avisar, y el estado "Sin conexión" de Inicio
/// sigue apareciendo al instante.
///
/// Solo LEE `isConnectedProvider` (nunca lo modifica): ese provider tiene
/// consumidores sensibles, entre ellos el guard que gatea el relleno de la
/// cola de radio del reproductor.
bool Function() _networkStillPlausible(Ref ref) =>
    () => ref.read(isConnectedProvider).value ?? true;

// ---------------------------------------------------------------------------
// Catálogo de Deezer para Inicio (todo cacheado en disco con TTL)
// ---------------------------------------------------------------------------

/// Playlists editoriales del chart general.
final editorialPlaylistsProvider = FutureProvider<List<DeezerPlaylist>>((ref) async {
  final deezerApi = ref.watch(deezerApiProvider);
  final cache = ref.watch(apiCacheProvider);
  return cache.fetch<List<DeezerPlaylist>>(
    key: 'editorial_playlists',
    ttl: CacheTtl.charts,
    fetcher: () => retryOnNetworkError(
      deezerApi.getEditorialPlaylists,
      shouldRetry: _networkStillPlausible(ref),
    ),
    encode: (list) => list.map((p) => p.toJson()).toList(),
    decode: (json) => json is List
        ? json
            .whereType<Map>()
            .map((item) => DeezerPlaylist.fromJson(Map<String, dynamic>.from(item)))
            .toList()
        : const [],
  );
});

/// Álbumes destacados del chart. Es el respaldo de "Novedades de tus artistas"
/// para quien todavía no tiene historial.
final newReleasesProvider = FutureProvider<List<DeezerAlbum>>((ref) async {
  final deezerApi = ref.watch(deezerApiProvider);
  final cache = ref.watch(apiCacheProvider);
  return cache.fetch<List<DeezerAlbum>>(
    key: 'chart_albums',
    ttl: CacheTtl.charts,
    fetcher: () => retryOnNetworkError(
      deezerApi.getNewReleases,
      shouldRetry: _networkStillPlausible(ref),
    ),
    encode: (list) => list.map((a) => a.toJson()).toList(),
    decode: (json) => json is List
        ? json
            .whereType<Map>()
            .map((item) => DeezerAlbum.fromJson(Map<String, dynamic>.from(item)))
            .toList()
        : const [],
  );
});

// ---------------------------------------------------------------------------
// Tops por país
// ---------------------------------------------------------------------------

/// Países que se muestran en Inicio sin tener que abrir la lista completa.
///
/// México primero porque es el mercado para el que se desarrolla la app; el
/// resto son los tops con más tráfico en la región más "Worldwide". La lista
/// completa (más de 100 países) vive detrás de "Ver todos", para no convertir
/// Inicio en un atlas.
const List<String> homeFeaturedCountryTops = [
  'top mexico',
  'top worldwide',
  'top usa',
  'top spain',
  'top argentina',
  'top colombia',
  'top brazil',
  'top chile',
  'top peru',
  'top france',
  'top germany',
  'top japan',
];

/// Ordena las playlists "Top {país}" dejando primero las destacadas, en el
/// orden de [homeFeaturedCountryTops].
///
/// Función pura y separada para poder testear el orden sin red.
List<DeezerPlaylist> sortCountryTopsForHome(List<DeezerPlaylist> playlists) {
  int rank(DeezerPlaylist p) {
    final index = homeFeaturedCountryTops.indexOf(p.title.toLowerCase().trim());
    return index == -1 ? homeFeaturedCountryTops.length : index;
  }

  final sorted = List<DeezerPlaylist>.from(playlists)
    ..sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      return a.title.compareTo(b.title);
    });
  return sorted;
}

/// Tops por país ya ordenados para Inicio.
final homeCountryTopsProvider = FutureProvider<List<DeezerPlaylist>>((ref) async {
  final all = await ref.watch(deezerCountryTopsProvider.future);
  return sortCountryTopsForHome(all);
});

// ---------------------------------------------------------------------------
// Secciones derivadas del historial del usuario
// ---------------------------------------------------------------------------

/// Algo que el usuario ya escuchó y puede retomar de un toque.
///
/// Nunca es una canción suelta: son playlists y álbumes, que es lo que tiene
/// sentido "seguir escuchando". (Regla de diseño de Inicio: ninguna canción
/// individual se presenta como si fuera una colección.)
class RecentlyPlayedItem {
  final String title;
  final String subtitle;
  final String? coverUrl;
  final String route;

  /// Para las playlists locales: permite que la portada por defecto sea la
  /// cuadrícula generada con sus primeras pistas, como en Biblioteca.
  final int? localPlaylistId;

  final DateTime playedAt;

  const RecentlyPlayedItem({
    required this.title,
    required this.subtitle,
    required this.coverUrl,
    required this.route,
    required this.playedAt,
    this.localPlaylistId,
  });
}

/// Playlists y álbumes guardados, ordenados por última reproducción.
///
/// Sale entero de Drift: aparece al instante, funciona sin conexión y no
/// gasta ni una petición. `lastPlayedAt` ya se escribía desde la ronda 3 pero
/// **nadie lo leía** — esta sección es su primer consumidor real.
final recentlyPlayedProvider = FutureProvider<List<RecentlyPlayedItem>>((ref) async {
  final playlistDao = ref.watch(playlistDaoProvider);
  final albumDao = ref.watch(savedAlbumDaoProvider);

  final playlists = await playlistDao.getAllPlaylists();
  final albums = await albumDao.getAllSavedAlbums();

  final items = <RecentlyPlayedItem>[];

  for (final playlist in playlists) {
    final playedAt = playlist.lastPlayedAt;
    if (playedAt == null) continue;
    items.add(RecentlyPlayedItem(
      title: playlist.title,
      subtitle: playlist.isLiked ? 'Tus me gusta' : 'Playlist',
      coverUrl: playlist.coverUrl,
      route: playlist.isLiked ? '/playlist/liked' : '/playlist/${playlist.id}',
      playedAt: playedAt,
      localPlaylistId: playlist.id,
    ));
  }

  for (final album in albums) {
    final playedAt = album.lastPlayedAt;
    if (playedAt == null) continue;
    items.add(RecentlyPlayedItem(
      title: album.title,
      subtitle: 'Álbum • ${album.artistName}',
      coverUrl: album.coverUrl,
      route: '/album/${album.albumId}',
      playedAt: playedAt,
    ));
  }

  items.sort((a, b) => b.playedAt.compareTo(a.playedAt));
  return items.take(10).toList();
});

/// Lanzamientos recientes de los artistas que el usuario más escucha.
///
/// Deezer no tiene endpoint de novedades (`/editorial/{id}/releases` devuelve
/// vacío siempre, verificado en vivo), así que se arma pidiendo la discografía
/// de sus top artistas — cacheada 24 h por artista — y filtrando por fecha de
/// lanzamiento en [MixEngine.filterRecentReleases].
final newReleasesFromArtistsProvider = FutureProvider<List<DeezerAlbum>>((ref) async {
  final historyDao = ref.watch(listeningHistoryDaoProvider);
  final entries = await historyDao.getRecentHistory(limit: 500);
  final now = DateTime.now();
  final artistIds = MixEngine.rankArtistIds(entries, now: now, limit: 4);
  if (artistIds.isEmpty) return const [];

  await settleAfterFirstPaint();

  final all = <DeezerAlbum>[];
  for (final artistId in artistIds) {
    try {
      final albums = await ref.read(deezerArtistAlbumsProvider(artistId).future);
      // `/artist/{id}/albums` no trae el objeto `artist`, así que estos
      // álbumes llegan como "Artista Desconocido". El nombre se rellena con
      // la ficha del artista, que ya está cacheada.
      String artistName = '';
      try {
        artistName = (await ref.read(deezerArtistProvider(artistId).future)).name;
      } catch (_) {}

      all.addAll(artistName.isEmpty
          ? albums
          : albums.map((a) => a.withArtist(artistId: artistId, artistName: artistName)));
    } catch (_) {
      // Un artista que falla no debe tumbar la sección entera.
    }
  }

  return MixEngine.filterRecentReleases(all, now: now, withinDays: 90, limit: 12);
});

/// "Porque escuchaste a X": artistas parecidos al que más escucha.
class RelatedArtistsSuggestion {
  final String seedArtistName;
  final List<DeezerArtist> artists;

  const RelatedArtistsSuggestion({required this.seedArtistName, required this.artists});
}

/// Una sección "Porque escuchaste a X" por cada uno de los artistas que más
/// escucha el usuario (los dos primeros de los últimos 60 días).
final relatedArtistsProvider = FutureProvider<List<RelatedArtistsSuggestion>>((ref) async {
  final historyDao = ref.watch(listeningHistoryDaoProvider);
  final api = ref.watch(deezerApiProvider);

  final entries = await historyDao.getRecentHistory(limit: 500);
  final artistIds = MixEngine.rankArtistIds(entries, now: DateTime.now(), limit: 2);
  if (artistIds.isEmpty) return const [];

  await settleAfterFirstPaint();

  final suggestions = <RelatedArtistsSuggestion>[];
  final alreadySuggested = <int>{...artistIds};

  for (final seedId in artistIds) {
    try {
      final seed = await ref.read(deezerArtistProvider(seedId).future);
      if (seed.name.isEmpty) continue;

      final related = await api.getArtistRelated(seedId);
      // Sin esto, las dos secciones se solapaban: artistas parecidos suelen
      // serlo entre sí, y el usuario veía dos filas casi idénticas.
      final fresh = related.where((a) => alreadySuggested.add(a.id)).take(12).toList();
      if (fresh.isEmpty) continue;

      suggestions.add(RelatedArtistsSuggestion(seedArtistName: seed.name, artists: fresh));
    } catch (_) {}
  }

  return suggestions;
});
