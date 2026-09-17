import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/api_cache.dart';
import '../../core/utils/connectivity_service.dart';
import '../../core/utils/startup_retry.dart';
import '../models/deezer/deezer_album.dart';
import '../models/deezer/deezer_artist.dart';
import '../models/deezer/deezer_genre.dart';
import '../models/deezer/deezer_playlist.dart';
import '../models/deezer/deezer_track.dart';
import 'deezer_provider.dart';

/// Providers del **catálogo público** de Deezer, con caché persistente.
///
/// Separados de `home_providers.dart` a propósito: esto lo consumen tanto
/// Inicio como Búsqueda, la pantalla de género y la de playlist de Deezer, y
/// nada de acá depende del usuario.
///
/// Todos pasan por [ApiCache], que es lo que hace que un arranque en frío
/// pinte contenido al instante en vez de esperar a la red, y que la app
/// siga mostrando algo sin conexión (ver `api_cache.dart`).

/// Corte de reintentos: estando realmente sin red no se quema el presupuesto
/// entero antes de rendirse (mismo criterio que `home_providers.dart`).
bool Function() networkStillPlausible(Ref ref) =>
    () => ref.read(isConnectedProvider).value ?? true;

List<T> _decodeList<T>(Object json, T Function(Map<String, dynamic>) builder) {
  if (json is! List) return const [];
  return json
      .whereType<Map>()
      .map((item) => builder(Map<String, dynamic>.from(item)))
      .toList();
}

/// Lista de géneros de Deezer, ya localizada por región.
final deezerGenresProvider = FutureProvider<List<DeezerGenre>>((ref) async {
  final api = ref.watch(deezerApiProvider);
  final cache = ref.watch(apiCacheProvider);
  return cache.fetch<List<DeezerGenre>>(
    key: 'genres',
    ttl: CacheTtl.catalog,
    fetcher: () => retryOnNetworkError(api.getGenres, shouldRetry: networkStillPlausible(ref)),
    encode: (list) => list.map((g) => g.toJson()).toList(),
    decode: (json) => _decodeList(json, DeezerGenre.fromJson),
  );
});

/// Chart completo de un género: pistas, álbumes, artistas y playlists en una
/// sola petición a `/chart/{genre_id}`.
final deezerGenreChartProvider =
    FutureProvider.family<DeezerGenreChart, int>((ref, genreId) async {
  final api = ref.watch(deezerApiProvider);
  final cache = ref.watch(apiCacheProvider);
  return cache.fetch<DeezerGenreChart>(
    key: 'genre_chart_$genreId',
    ttl: CacheTtl.charts,
    fetcher: () => retryOnNetworkError(
      () => api.getGenreChart(genreId),
      shouldRetry: networkStillPlausible(ref),
    ),
    encode: (chart) => chart.toJson(),
    decode: (json) => json is Map
        ? DeezerGenreChart.fromJson(Map<String, dynamic>.from(json))
        : const DeezerGenreChart(),
  );
});

/// Radios editoriales de un género.
final deezerGenreRadiosProvider =
    FutureProvider.family<List<DeezerRadio>, int>((ref, genreId) async {
  final api = ref.watch(deezerApiProvider);
  final cache = ref.watch(apiCacheProvider);
  return cache.fetch<List<DeezerRadio>>(
    key: 'genre_radios_$genreId',
    ttl: CacheTtl.catalog,
    fetcher: () => retryOnNetworkError(
      () => api.getGenreRadios(genreId),
      shouldRetry: networkStillPlausible(ref),
    ),
    encode: (list) => list.map((r) => r.toJson()).toList(),
    decode: (json) => _decodeList(json, DeezerRadio.fromJson),
  );
});

/// Playlist de Deezer con sus pistas.
///
/// TTL corto comparado con el resto del catálogo: los "Top {país}" cambian
/// a diario y es justo lo que el usuario espera ver fresco.
final deezerPlaylistProvider =
    FutureProvider.family<DeezerPlaylist, int>((ref, playlistId) async {
  final api = ref.watch(deezerApiProvider);
  final cache = ref.watch(apiCacheProvider);
  return cache.fetch<DeezerPlaylist>(
    key: 'playlist_$playlistId',
    ttl: CacheTtl.charts,
    fetcher: () => retryOnNetworkError(
      () => api.getPlaylist(playlistId),
      shouldRetry: networkStillPlausible(ref),
    ),
    encode: (playlist) => playlist.toJson(),
    decode: (json) => json is Map
        ? DeezerPlaylist.fromJson(Map<String, dynamic>.from(json))
        : const DeezerPlaylist(id: 0, title: '', pictureUrl: '', nbTracks: 0, userName: ''),
  );
});

/// Las ~100 playlists "Top {país}" oficiales de Deezer.
final deezerCountryTopsProvider = FutureProvider<List<DeezerPlaylist>>((ref) async {
  final api = ref.watch(deezerApiProvider);
  final cache = ref.watch(apiCacheProvider);
  return cache.fetch<List<DeezerPlaylist>>(
    key: 'country_tops',
    ttl: CacheTtl.catalog,
    fetcher: () => retryOnNetworkError(
      api.getCountryTopPlaylists,
      shouldRetry: networkStillPlausible(ref),
    ),
    encode: (list) => list.map((p) => p.toJson()).toList(),
    decode: (json) => _decodeList(json, DeezerPlaylist.fromJson),
  );
});

/// Ficha de artista cacheada (nombre y foto), para no repetir `/artist/{id}`
/// en cada arranque solo para poner el título de un mix.
final deezerArtistProvider = FutureProvider.family<DeezerArtist, int>((ref, artistId) async {
  final api = ref.watch(deezerApiProvider);
  final cache = ref.watch(apiCacheProvider);
  return cache.fetch<DeezerArtist>(
    key: 'artist_$artistId',
    ttl: CacheTtl.catalog,
    fetcher: () => retryOnNetworkError(
      () => api.getArtist(artistId),
      shouldRetry: networkStillPlausible(ref),
    ),
    encode: (artist) => artist.toJson(),
    decode: (json) => json is Map
        ? DeezerArtist.fromJson(Map<String, dynamic>.from(json))
        : const DeezerArtist(id: 0, name: '', pictureUrl: '', nbFan: 0),
  );
});

/// Álbum cacheado. Se usa para deducir el género dominante del usuario a
/// partir de lo que escuchó (`genre_id` solo viene en `/album/{id}`).
final deezerAlbumProvider = FutureProvider.family<DeezerAlbum, int>((ref, albumId) async {
  final api = ref.watch(deezerApiProvider);
  final cache = ref.watch(apiCacheProvider);
  return cache.fetch<DeezerAlbum>(
    key: 'album_meta_$albumId',
    ttl: CacheTtl.catalog,
    fetcher: () => retryOnNetworkError(
      () => api.getAlbum(albumId),
      shouldRetry: networkStillPlausible(ref),
    ),
    // Solo se cachea la ficha, no el tracklist: eso lo pide la pantalla de
    // álbum, que necesita datos frescos y ya tiene su propio flujo.
    encode: (album) => album.toJson(),
    decode: (json) => json is Map
        ? DeezerAlbum.fromJson(Map<String, dynamic>.from(json))
        : const DeezerAlbum(
            id: 0,
            title: '',
            artistName: '',
            artistId: 0,
            coverUrl: '',
            trackCount: 0,
            releaseDate: '',
          ),
  );
});

/// Discografía de un artista, cacheada un día — base de "Novedades de tus
/// artistas" (Deezer no tiene endpoint de novedades; ver `MixEngine`).
final deezerArtistAlbumsProvider =
    FutureProvider.family<List<DeezerAlbum>, int>((ref, artistId) async {
  final api = ref.watch(deezerApiProvider);
  final cache = ref.watch(apiCacheProvider);
  return cache.fetch<List<DeezerAlbum>>(
    key: 'artist_albums_$artistId',
    ttl: CacheTtl.daily,
    fetcher: () => retryOnNetworkError(
      () => api.getArtistAlbums(artistId),
      shouldRetry: networkStillPlausible(ref),
    ),
    encode: (list) => list.map((a) => a.toJson()).toList(),
    decode: (json) => _decodeList(json, DeezerAlbum.fromJson),
  );
});

/// Pistas de una radio editorial de Deezer.
///
/// ⚠️ **Sin caché a propósito**: `/radio/{id}/tracks` no es determinista, así
/// que cachearlo daría una falsa sensación de estabilidad. La estabilidad la
/// da el provider que consume esto (ver `mix_providers.dart`), manteniendo
/// viva la tirada durante la sesión.
final deezerRadioTracksProvider =
    FutureProvider.family<List<DeezerTrack>, int>((ref, radioId) async {
  final api = ref.watch(deezerApiProvider);
  return retryOnNetworkError(
    () => api.getRadioTracks(radioId),
    shouldRetry: networkStillPlausible(ref),
  );
});
