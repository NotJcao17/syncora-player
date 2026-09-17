import 'deezer_album.dart';
import 'deezer_artist.dart';
import 'deezer_playlist.dart';
import 'deezer_track.dart';

/// Género del catálogo de Deezer (`/genre`).
///
/// La lista llega **ya localizada** por el idioma/región que Deezer infiere
/// de la IP (verificado en vivo: desde México devuelve "Reggaetón", "Música
/// Mexicana", "Clásica"), así que no hace falta traducir nada a mano ni
/// mantener una lista hardcodeada como la que tenía la pantalla de búsqueda.
class DeezerGenre {
  final int id;
  final String name;
  final String pictureUrl;

  const DeezerGenre({
    required this.id,
    required this.name,
    required this.pictureUrl,
  });

  factory DeezerGenre.fromJson(Map<String, dynamic> json) {
    return DeezerGenre(
      id: json['id'] as int? ?? 0,
      name: json['name'] as String? ?? 'Género',
      pictureUrl: json['picture_big'] as String? ??
          json['picture_medium'] as String? ??
          json['picture_xl'] as String? ??
          json['picture'] as String? ??
          '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'picture_big': pictureUrl,
      };
}

/// Radio editorial de Deezer (`/radio`, `/genre/{id}/radios`).
///
/// ⚠️ Una radio **no es una playlist estable**: `/radio/{id}/tracks` devuelve
/// una selección distinta en cada llamada (verificado pidiéndola dos veces
/// con un segundo de diferencia). Por eso en Syncora una radio nunca se
/// "sigue" ni se guarda por referencia — si el usuario la guarda, se congela
/// una copia local, igual que con nuestros propios mixes.
class DeezerRadio {
  final int id;
  final String title;
  final String pictureUrl;

  const DeezerRadio({
    required this.id,
    required this.title,
    required this.pictureUrl,
  });

  factory DeezerRadio.fromJson(Map<String, dynamic> json) {
    return DeezerRadio(
      id: json['id'] as int? ?? 0,
      title: (json['title'] as String? ?? 'Radio').trim(),
      pictureUrl: json['picture_big'] as String? ??
          json['picture_medium'] as String? ??
          json['picture_xl'] as String? ??
          json['picture'] as String? ??
          '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'picture_big': pictureUrl,
      };
}

/// Respuesta de `/chart/{genre_id}`: en **una sola petición** trae las cuatro
/// listas que necesita la pantalla de género (además de `podcasts`, que
/// Syncora ignora por diseño — la app filtra podcasts en todos lados).
class DeezerGenreChart {
  final List<DeezerTrack> tracks;
  final List<DeezerAlbum> albums;
  final List<DeezerArtist> artists;
  final List<DeezerPlaylist> playlists;

  const DeezerGenreChart({
    this.tracks = const [],
    this.albums = const [],
    this.artists = const [],
    this.playlists = const [],
  });

  bool get isEmpty => tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty;

  factory DeezerGenreChart.fromJson(Map<String, dynamic> json) {
    List<T> parse<T>(String key, T Function(Map<String, dynamic>) builder, {bool Function(Map)? where}) {
      final section = json[key];
      if (section is! Map || section['data'] is! List) return const [];
      final out = <T>[];
      for (final item in section['data'] as List) {
        if (item is! Map) continue;
        if (where != null && !where(item)) continue;
        out.add(builder(Map<String, dynamic>.from(item)));
      }
      return out;
    }

    final tracks = parse<DeezerTrack>(
      'tracks',
      DeezerTrack.fromJson,
      where: (item) => (item['duration'] as int? ?? 0) > 60 && item['type'] != 'podcast',
    );

    return DeezerGenreChart(
      tracks: tracks,
      albums: parse<DeezerAlbum>('albums', DeezerAlbum.fromJson),
      artists: parse<DeezerArtist>('artists', DeezerArtist.fromJson),
      playlists: parse<DeezerPlaylist>('playlists', DeezerPlaylist.fromJson),
    );
  }

  Map<String, dynamic> toJson() => {
        'tracks': {'data': tracks.map((t) => t.toJson()).toList()},
        'albums': {'data': albums.map((a) => a.toJson()).toList()},
        'artists': {'data': artists.map((a) => a.toJson()).toList()},
        'playlists': {'data': playlists.map((p) => p.toJson()).toList()},
      };
}
