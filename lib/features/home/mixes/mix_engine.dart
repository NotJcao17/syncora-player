import '../../../data/local_db/syncora_database.dart';
import '../../../data/models/deezer/deezer_album.dart';

/// Lógica pura de los mixes de Inicio: claves de periodo, conteo de repeticiones
/// y selección determinista.
///
/// Todo acá es función pura y testeable — ni red, ni base de datos, ni
/// `DateTime.now()` implícito (el `now` siempre se pasa). Mismo patrón que
/// `StatsCalculator` (7.G) y `computeCanEdit`/`computeAuthRedirect` (7.I).
class MixEngine {
  /// Ventana de "lo que más repetiste últimamente".
  static const int onRepeatWindowDays = 30;

  /// Mínimo de escuchas para considerar que una pista está *en repetición*.
  /// Con 1 sola escucha no hay repetición, hay una canción escuchada.
  static const int onRepeatMinPlays = 2;

  /// Clave de periodo semanal, ISO-8601 (`2026-W38`).
  ///
  /// Los mixes semanales se renuevan al cambiar esta clave: en la práctica,
  /// el lunes. No hay cron ni servidor detrás — la clave se calcula en el
  /// cliente cada vez que se arma un mix, y con eso alcanza.
  static String weekKey(DateTime now) {
    final date = DateTime(now.year, now.month, now.day);
    // Jueves de la misma semana ISO: define a qué año pertenece la semana.
    final thursday = date.add(Duration(days: 4 - date.weekday));
    final firstThursday = DateTime(thursday.year, 1, 4);
    final firstMonday = firstThursday.subtract(Duration(days: firstThursday.weekday - 1));
    final week = (thursday.difference(firstMonday).inDays ~/ 7) + 1;
    return '${thursday.year}-W${week.toString().padLeft(2, '0')}';
  }

  /// Clave de periodo diaria (`2026-09-17`).
  static String dayKey(DateTime now) =>
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

  /// Semilla entera estable derivada de una clave de periodo, para que la
  /// selección "al azar" del día sea la misma durante todo el día.
  static int seedFrom(String periodKey) {
    var hash = 0;
    for (final unit in periodKey.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash;
  }

  /// IDs de pistas más repetidas en la ventana de [onRepeatWindowDays],
  /// ordenadas por número de escuchas y, a igualdad, por escucha más reciente.
  ///
  /// Solo entran las que superan [onRepeatMinPlays]; si eso deja la lista
  /// demasiado corta para ser un mix, el llamador decide no mostrar nada
  /// (mejor sin sección que una sección de 3 pistas).
  static List<int> rankOnRepeatTrackIds(
    List<ListeningHistoryData> entries, {
    required DateTime now,
    int limit = 30,
  }) {
    final cutoff = now.subtract(const Duration(days: onRepeatWindowDays));
    final plays = <int, int>{};
    final lastPlayed = <int, DateTime>{};

    for (final entry in entries) {
      if (entry.trackId <= 0) continue;
      if (entry.listenedAt.isBefore(cutoff)) continue;
      plays[entry.trackId] = (plays[entry.trackId] ?? 0) + 1;
      final previous = lastPlayed[entry.trackId];
      if (previous == null || entry.listenedAt.isAfter(previous)) {
        lastPlayed[entry.trackId] = entry.listenedAt;
      }
    }

    final ranked = plays.entries.where((e) => e.value >= onRepeatMinPlays).toList()
      ..sort((a, b) {
        final byPlays = b.value.compareTo(a.value);
        if (byPlays != 0) return byPlays;
        return (lastPlayed[b.key] ?? DateTime(0)).compareTo(lastPlayed[a.key] ?? DateTime(0));
      });

    return ranked.take(limit).map((e) => e.key).toList();
  }

  /// Álbumes más escuchados (por número de escuchas) dentro de la ventana,
  /// para deducir de ahí el género dominante del usuario.
  static List<int> rankAlbumIds(
    List<ListeningHistoryData> entries, {
    required DateTime now,
    int windowDays = 60,
    int limit = 5,
  }) {
    final cutoff = now.subtract(Duration(days: windowDays));
    final counts = <int, int>{};
    for (final entry in entries) {
      if (entry.albumId <= 0) continue;
      if (entry.listenedAt.isBefore(cutoff)) continue;
      counts[entry.albumId] = (counts[entry.albumId] ?? 0) + 1;
    }
    final sorted = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(limit).map((e) => e.key).toList();
  }

  /// IDs de artista más escuchados en la ventana, ordenados por escuchas.
  ///
  /// Se prefiere esto a `ListeningHistoryDao.getTopArtistIds()` porque aquel
  /// mira solo las últimas 100 filas del historial sin ventana temporal, y
  /// acá hace falta acotar por fecha para que los mixes reflejen lo que el
  /// usuario escucha *ahora*.
  static List<int> rankArtistIds(
    List<ListeningHistoryData> entries, {
    required DateTime now,
    int windowDays = 60,
    int limit = 5,
  }) {
    final cutoff = now.subtract(Duration(days: windowDays));
    final counts = <int, int>{};
    for (final entry in entries) {
      if (entry.artistId <= 0) continue;
      if (entry.listenedAt.isBefore(cutoff)) continue;
      counts[entry.artistId] = (counts[entry.artistId] ?? 0) + 1;
    }
    final sorted = counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(limit).map((e) => e.key).toList();
  }

  /// Todos los IDs de pista que el usuario ya escuchó (para poder excluirlos
  /// del mix de descubrimiento).
  static Set<int> listenedTrackIds(List<ListeningHistoryData> entries) =>
      entries.where((e) => e.trackId > 0).map((e) => e.trackId).toSet();

  /// Lanzamientos recientes a partir de una discografía completa.
  ///
  /// Deezer **no tiene endpoint de novedades**: `/editorial/{id}/releases`
  /// devuelve siempre `{"data":[],"total":0}` (verificado en vivo con varios
  /// géneros) y `/chart/0/albums` son los álbumes más *escuchados*, no los
  /// más nuevos. Así que las novedades se calculan acá, filtrando por
  /// `release_date` la discografía que ya sabemos pedir.
  ///
  /// Descarta fechas futuras: Deezer publica fichas con fecha de lanzamiento
  /// por delante, y colarlas en "novedades" mostraría álbumes que todavía no
  /// existen.
  static List<DeezerAlbum> filterRecentReleases(
    List<DeezerAlbum> albums, {
    required DateTime now,
    int withinDays = 60,
    int limit = 20,
  }) {
    final cutoff = DateTime(now.year, now.month, now.day).subtract(Duration(days: withinDays));
    final today = DateTime(now.year, now.month, now.day);

    final dated = <MapEntry<DateTime, DeezerAlbum>>[];
    final seenTitles = <String>{};

    for (final album in albums) {
      final date = DateTime.tryParse(album.releaseDate);
      if (date == null) continue;
      if (date.isBefore(cutoff)) continue;
      if (date.isAfter(today)) continue;
      // Deezer duplica el mismo lanzamiento por territorio/edición; con el
      // título normalizado alcanza para no mostrar tres veces lo mismo.
      final titleKey = '${album.artistId}|${album.title.toLowerCase().trim()}';
      if (!seenTitles.add(titleKey)) continue;
      dated.add(MapEntry(date, album));
    }

    dated.sort((a, b) => b.key.compareTo(a.key));
    return dated.take(limit).map((e) => e.value).toList();
  }

  /// Baraja determinista: la misma [seed] siempre produce el mismo orden.
  ///
  /// Se usa para que el mix del día sea idéntico si se vuelve a construir
  /// dentro del mismo periodo, y distinto al día siguiente, sin guardar nada.
  static List<T> shuffleDeterministic<T>(List<T> items, int seed) {
    final out = List<T>.from(items);
    // LCG simple (mismos parámetros que `java.util.Random`), suficiente para
    // barajar una lista de decenas de elementos y con resultados idénticos en
    // todas las plataformas — a diferencia de `Random(seed)` de Dart, cuya
    // secuencia no está garantizada entre versiones.
    var state = (seed == 0 ? 1 : seed) & 0x7fffffff;
    int next(int max) {
      state = (state * 1103515245 + 12345) & 0x7fffffff;
      return state % max;
    }

    for (var i = out.length - 1; i > 0; i--) {
      final j = next(i + 1);
      final tmp = out[i];
      out[i] = out[j];
      out[j] = tmp;
    }
    return out;
  }
}
