import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/cache/api_cache.dart';
import '../../core/utils/connectivity_service.dart';
import '../../core/utils/startup_retry.dart';
import '../../data/apis/deezer_catalog_providers.dart';
import '../../data/apis/deezer_provider.dart';
import '../../data/local_db/daos/stats_metadata_cache_dao.dart';
import '../../data/local_db/database_provider.dart';
import '../../data/models/deezer/deezer_album.dart';
import '../../data/models/deezer/deezer_artist.dart';
import '../../data/models/deezer/deezer_playlist.dart';
import '../../data/models/deezer/deezer_track.dart';
import '../stats/stats_calculator.dart';
import '../stats/stats_providers.dart';
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

final relatedArtistsProvider = FutureProvider<RelatedArtistsSuggestion?>((ref) async {
  final historyDao = ref.watch(listeningHistoryDaoProvider);
  final api = ref.watch(deezerApiProvider);

  final entries = await historyDao.getRecentHistory(limit: 500);
  final artistIds = MixEngine.rankArtistIds(entries, now: DateTime.now(), limit: 1);
  if (artistIds.isEmpty) return null;

  await settleAfterFirstPaint();

  final seedId = artistIds.first;
  try {
    final seed = await ref.read(deezerArtistProvider(seedId).future);
    final related = await api.getArtistRelated(seedId);
    if (related.isEmpty || seed.name.isEmpty) return null;
    return RelatedArtistsSuggestion(seedArtistName: seed.name, artists: related.take(12).toList());
  } catch (_) {
    return null;
  }
});

// ---------------------------------------------------------------------------
// Resumen de estadísticas de la semana
// ---------------------------------------------------------------------------

/// Datos del panel de estadísticas de Inicio.
///
/// Es un **resumen**, no la pantalla de Estadísticas: minutos de la semana y
/// los tres primeros de cada top. La Fase 8 va a reemplazar la pantalla
/// completa por un dashboard; esta tarjeta está pensada para ser la entrada a
/// ese dashboard, no algo que haya que tirar.
class WeeklyHighlights {
  final int totalMinutes;
  final List<EnrichedArtist> topArtists;
  final List<EnrichedTrack> topTracks;

  const WeeklyHighlights({
    required this.totalMinutes,
    required this.topArtists,
    required this.topTracks,
  });

  bool get isEmpty => totalMinutes == 0 && topArtists.isEmpty && topTracks.isEmpty;
}

/// Top 3 de artistas y canciones de la semana, ya con nombre y portada.
///
/// Provider propio (y no los `family` de Estadísticas) porque aquellos se
/// indexan por una `List<StatEntry>`, que no tiene igualdad por valor: desde
/// Inicio, que se reconstruye a menudo, cada rebuild crearía una instancia
/// nueva del provider y volvería a resolver todo.
final weeklyHighlightsProvider = FutureProvider<WeeklyHighlights>((ref) async {
  final snapshot = await ref.watch(weeklyStatsProvider.future);
  if (snapshot.isEmpty) {
    return const WeeklyHighlights(totalMinutes: 0, topArtists: [], topTracks: []);
  }

  final topArtistEntries = snapshot.topArtists.take(3).toList();
  final topTrackEntries = snapshot.topTracks.take(3).toList();

  final results = await Future.wait([
    _enrichArtists(ref, topArtistEntries),
    _enrichTracks(ref, topTrackEntries),
  ]);

  return WeeklyHighlights(
    totalMinutes: snapshot.totalMinutes,
    topArtists: results[0] as List<EnrichedArtist>,
    topTracks: results[1] as List<EnrichedTrack>,
  );
});

Future<List<EnrichedArtist>> _enrichArtists(Ref ref, List<StatEntry> entries) async {
  if (entries.isEmpty) return const [];
  final cacheDao = ref.read(statsMetadataCacheDaoProvider);
  final api = ref.read(deezerApiProvider);
  final cached = await cacheDao.getMany(StatsEntityType.artist, entries.map((e) => e.id).toSet());

  final results = await Future.wait(entries.map((entry) async {
    final hit = cached[entry.id];
    if (hit != null) {
      return EnrichedArtist(
        entry: entry,
        artist: DeezerArtist(id: entry.id, name: hit.primaryName, pictureUrl: hit.coverUrl, nbFan: 0),
      );
    }
    try {
      final artist = await api.getArtist(entry.id);
      await cacheDao.upsert(
        entityType: StatsEntityType.artist,
        entityId: entry.id,
        primaryName: artist.name,
        coverUrl: artist.pictureUrl,
      );
      return EnrichedArtist(entry: entry, artist: artist);
    } catch (_) {
      return null;
    }
  }));

  return results.whereType<EnrichedArtist>().toList();
}

Future<List<EnrichedTrack>> _enrichTracks(Ref ref, List<StatEntry> entries) async {
  if (entries.isEmpty) return const [];
  final cacheDao = ref.read(statsMetadataCacheDaoProvider);
  final api = ref.read(deezerApiProvider);
  final cached = await cacheDao.getMany(StatsEntityType.track, entries.map((e) => e.id).toSet());

  final results = await Future.wait(entries.map((entry) async {
    final hit = cached[entry.id];
    if (hit != null) {
      return EnrichedTrack(
        entry: entry,
        track: DeezerTrack(
          id: entry.id,
          title: hit.primaryName,
          artistName: hit.secondaryName ?? '',
          artistId: 0,
          albumTitle: '',
          albumId: 0,
          coverUrl: hit.coverUrl,
          durationSec: 0,
        ),
      );
    }
    try {
      final track = await api.getTrack(entry.id);
      await cacheDao.upsert(
        entityType: StatsEntityType.track,
        entityId: entry.id,
        primaryName: track.title,
        secondaryName: track.artistName,
        coverUrl: track.coverUrl,
      );
      return EnrichedTrack(entry: entry, track: track);
    } catch (_) {
      return null;
    }
  }));

  return results.whereType<EnrichedTrack>().toList();
}
