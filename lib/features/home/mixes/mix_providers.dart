import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/apis/deezer_catalog_providers.dart';
import '../../../data/apis/deezer_api.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../core/utils/startup_retry.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../../data/models/deezer/deezer_artist.dart';
import 'mix_engine.dart';
import 'mix_models.dart';
import 'track_resolver.dart';

final trackResolverProvider = Provider<TrackResolver>((ref) {
  return TrackResolver(
    playlistDao: ref.watch(playlistDaoProvider),
    downloadedTrackDao: ref.watch(downloadedTrackDaoProvider),
    deezerApi: ref.watch(deezerApiProvider),
  );
});

/// Cuántas escuchas hacen falta para que Inicio muestre mixes personales.
/// Por debajo de esto, "lo que más repetiste" no significa nada todavía.
const int _minHistoryEntriesForMixes = 5;

/// Mínimo de pistas para que un mix valga la pena mostrarse.
const int _minTracksPerMix = 8;

/// Tope de pistas por mix.
const int _maxTracksPerMix = 40;

/// Cuántos mixes de cada tipo se generan.
///
/// Subidos tras las pruebas en dispositivo: con 4 mixes la fila de Inicio ni
/// siquiera llenaba la pantalla. Ahora son hasta 9 y la sección se siente
/// como contenido, no como un hueco.
const int _artistMixCount = 4;
const int _genreMixCount = 2;
const int _genreRadioMixCount = 2;

/// Los mixes de la sesión.
///
/// **Deliberadamente NO es `autoDispose`.** Esa es toda la implementación de
/// la regla que acordamos: el mix se construye una vez por arranque de la app
/// y queda vivo en memoria, así que entrar y salir de él —o volver a Inicio—
/// muestra siempre exactamente la misma lista. Al cerrar y reabrir la app se
/// genera de nuevo, que es el comportamiento buscado.
///
/// Nada de esto se escribe en la base de datos: un mix solo se materializa
/// como playlist real si el usuario pulsa "Guardar" (ver `SyncoraMix`).
///
/// Cada mix se arma en su propio `try`: si Deezer falla para uno, los demás
/// siguen apareciendo.
///
/// "On Repeat" **no está acá**: es una playlist permanente, no un mix efímero
/// (ver `on_repeat_service.dart`).
final mixesProvider = FutureProvider<List<SyncoraMix>>((ref) async {
  final historyDao = ref.watch(listeningHistoryDaoProvider);
  final api = ref.watch(deezerApiProvider);

  final entries = await historyDao.getRecentHistory(limit: 500);
  if (entries.length < _minHistoryEntriesForMixes) return const [];

  // Los mixes no son urgentes: que el primer frame y una reproducción
  // inmediata ganen la carrera por el hilo principal y por la red.
  await settleAfterFirstPaint();

  final now = DateTime.now();
  final daySeed = MixEngine.seedFrom(MixEngine.dayKey(now));
  final mixes = <SyncoraMix>[];

  await _addArtistMixes(mixes, ref, entries, api, now);
  await _addGenreMixes(mixes, ref, entries, now, daySeed);
  await _addDiscoveryMix(mixes, ref, entries, api, now, daySeed);
  await _addGenreRadioMixes(mixes, ref, entries, now, daySeed);

  return mixes;
});

/// Un mix concreto por su clave, para la pantalla de detalle.
///
/// Lee de [mixesProvider], así que la pantalla ve exactamente la misma tirada
/// que la tarjeta de Inicio desde la que se abrió.
final mixByKeyProvider = Provider.family<SyncoraMix?, String>((ref, key) {
  final mixes = ref.watch(mixesProvider).value;
  if (mixes == null) return null;
  for (final mix in mixes) {
    if (mix.key == key) return mix;
  }
  return null;
});

Future<void> _addArtistMixes(
  List<SyncoraMix> mixes,
  Ref ref,
  List<ListeningHistoryData> entries,
  DeezerApi api,
  DateTime now,
) async {
  final artistIds = MixEngine.rankArtistIds(entries, now: now, limit: _artistMixCount);
  final dayKey = MixEngine.dayKey(now);

  for (final artistId in artistIds) {
    try {
      // `getArtistRadio` tiene caché LRU por sesión dentro de `DeezerApi`, así
      // que la tirada ya queda fija sin esfuerzo extra aunque se vuelva a
      // pedir en el mismo arranque.
      final radio = await api.getArtistRadio(artistId);
      if (radio.length < _minTracksPerMix) continue;

      String name = 'tu artista';
      String cover = radio.first.coverUrl;
      try {
        final artist = await ref.read(deezerArtistProvider(artistId).future);
        if (artist.name.isNotEmpty) name = artist.name;
        if (artist.pictureUrl.isNotEmpty) cover = artist.pictureUrl;
      } catch (_) {}

      mixes.add(SyncoraMix(
        key: 'artist:$artistId:$dayKey',
        kind: MixKind.artist,
        title: 'Mix de $name',
        subtitle: 'Basado en lo que escuchás de $name',
        coverUrl: cover,
        tracks: radio.take(_maxTracksPerMix).map((t) => t.toSyncoraTrack()).toList(),
      ));
    } catch (_) {}
  }
}

Future<void> _addGenreMixes(
  List<SyncoraMix> mixes,
  Ref ref,
  List<ListeningHistoryData> entries,
  DateTime now,
  int daySeed,
) async {
  // El género no está en `listening_history` (queda NULL en el flujo normal de
  // reproducción, ver 7.0.3), así que se deduce de los álbumes más
  // escuchados: `/album/{id}` es el único endpoint barato que trae `genre_id`.
  final genreIds = await dominantGenreIds(ref, entries, now: now, limit: _genreMixCount);

  for (final genreId in genreIds) {
    try {
      final chart = await ref.read(deezerGenreChartProvider(genreId).future);
      if (chart.tracks.length < _minTracksPerMix) continue;

      final genreName = await _genreName(ref, genreId);
      final shuffled = MixEngine.shuffleDeterministic(chart.tracks, daySeed + genreId);

      mixes.add(SyncoraMix(
        key: 'genre:$genreId:${MixEngine.dayKey(now)}',
        kind: MixKind.genre,
        title: 'Mix de $genreName',
        subtitle: 'Lo que suena en $genreName',
        coverUrl: shuffled.first.coverUrl,
        tracks: shuffled.take(_maxTracksPerMix).map((t) => t.toSyncoraTrack()).toList(),
      ));
    } catch (_) {}
  }
}

/// Géneros dominantes del usuario, deducidos de los álbumes que más escucha.
///
/// Público porque lo usan tanto los mixes de género como los mixes temáticos
/// sacados de las radios editoriales de ese mismo género.
Future<List<int>> dominantGenreIds(
  Ref ref,
  List<ListeningHistoryData> entries, {
  required DateTime now,
  int limit = 2,
}) async {
  final albumIds = MixEngine.rankAlbumIds(entries, now: now, limit: 6);
  final genreIds = <int>[];

  for (final albumId in albumIds) {
    if (genreIds.length >= limit) break;
    try {
      final album = await ref.read(deezerAlbumProvider(albumId).future);
      if (album.genreId > 0 && !genreIds.contains(album.genreId)) {
        genreIds.add(album.genreId);
      }
    } catch (_) {}
  }

  return genreIds;
}

Future<String> _genreName(Ref ref, int genreId) async {
  try {
    final genres = await ref.read(deezerGenresProvider.future);
    for (final genre in genres) {
      if (genre.id == genreId) return genre.name;
    }
  } catch (_) {}
  return 'tu género';
}

/// Mixes temáticos a partir de las radios editoriales del género que más
/// escucha el usuario (`/genre/{id}/radios` devuelve 37 solo para Pop, con
/// nombres como "80's" o "Chill").
///
/// Es la fuente más barata de variedad que tiene la API: la lista de radios se
/// cachea una semana y solo se pagan las pistas de las que se muestran.
Future<void> _addGenreRadioMixes(
  List<SyncoraMix> mixes,
  Ref ref,
  List<ListeningHistoryData> entries,
  DateTime now,
  int daySeed,
) async {
  try {
    final genreIds = await dominantGenreIds(ref, entries, now: now, limit: 1);
    if (genreIds.isEmpty) return;

    final radios = await ref.read(deezerGenreRadiosProvider(genreIds.first).future);
    if (radios.isEmpty) return;

    // Rotan a diario, pero dentro del día son siempre las mismas.
    final rotated = MixEngine.shuffleDeterministic(radios, daySeed);

    for (final radio in rotated.take(_genreRadioMixCount)) {
      try {
        final tracks = await ref.read(deezerRadioTracksProvider(radio.id).future);
        if (tracks.length < _minTracksPerMix) continue;

        mixes.add(SyncoraMix(
          key: 'radio:${radio.id}:${MixEngine.dayKey(now)}',
          kind: MixKind.genre,
          title: radio.title,
          subtitle: 'Selección de Deezer',
          coverUrl: radio.pictureUrl.isNotEmpty ? radio.pictureUrl : tracks.first.coverUrl,
          tracks: tracks.take(_maxTracksPerMix).map((t) => t.toSyncoraTrack()).toList(),
        ));
      } catch (_) {}
    }
  } catch (_) {}
}

Future<void> _addDiscoveryMix(
  List<SyncoraMix> mixes,
  Ref ref,
  List<ListeningHistoryData> entries,
  DeezerApi api,
  DateTime now,
  int daySeed,
) async {
  try {
    final artistIds = MixEngine.rankArtistIds(entries, now: now, limit: 3);
    if (artistIds.isEmpty) return;

    final seedArtistId = artistIds.first;
    final List<DeezerArtist> related = await api.getArtistRelated(seedArtistId);
    if (related.isEmpty) return;

    // Un relacionado distinto cada día, pero el mismo durante todo el día.
    final rotated = MixEngine.shuffleDeterministic(related, daySeed);
    final target = rotated.first;

    final radio = await api.getArtistRadio(target.id);
    final alreadyHeard = MixEngine.listenedTrackIds(entries);
    // Descubrir es, literalmente, quitar lo que ya conoce.
    final fresh = radio.where((t) => !alreadyHeard.contains(t.id)).toList();
    if (fresh.length < _minTracksPerMix) return;

    // El nombre tiene que ser el del artista semilla, no el de la primera
    // pista de su radio: una radio está sembrada en un artista pero devuelve
    // sobre todo canciones de OTROS, así que aquello ponía un nombre casi al
    // azar en el subtítulo. `deezerArtistProvider` está cacheado, no cuesta
    // una petición nueva.
    String seedName = 'lo que escuchás';
    try {
      final seedArtist = await ref.read(deezerArtistProvider(seedArtistId).future);
      if (seedArtist.name.isNotEmpty) seedName = seedArtist.name;
    } catch (_) {}

    mixes.add(SyncoraMix(
      key: 'discovery:${target.id}:${MixEngine.dayKey(now)}',
      kind: MixKind.discovery,
      title: 'Descubrimiento',
      subtitle: 'Artistas como ${target.name}, a partir de $seedName',
      coverUrl: target.pictureUrl.isNotEmpty ? target.pictureUrl : fresh.first.coverUrl,
      tracks: fresh.take(_maxTracksPerMix).map((t) => t.toSyncoraTrack()).toList(),
    ));
  } catch (_) {}
}
