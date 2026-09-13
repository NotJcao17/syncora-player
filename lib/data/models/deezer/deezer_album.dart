import 'deezer_track.dart';

class DeezerAlbum {
  final int id;
  final String title;
  final String artistName;
  final int artistId;
  final String coverUrl;
  final int trackCount;
  final String releaseDate;
  final List<DeezerTrack> tracks;

  /// `record_type` de Deezer: `album`, `single`, `ep` o `compilation`.
  ///
  /// Ronda 3 (F1): el campo ya venía en la respuesta de
  /// `/artist/{id}/albums` y se estaba descartando, así que la discografía
  /// mezclaba álbumes con sencillos sin forma de separarlos. Leerlo no
  /// cuesta ninguna petición extra.
  ///
  /// Cadena vacía = el endpoint no lo trae (p. ej. `/album/{id}` embebido en
  /// otra respuesta); en ese caso [isSingleOrEp] devuelve `false` y el álbum
  /// se trata como álbum, que es el caso mayoritario.
  final String recordType;

  const DeezerAlbum({
    required this.id,
    required this.title,
    required this.artistName,
    required this.artistId,
    required this.coverUrl,
    required this.trackCount,
    required this.releaseDate,
    this.tracks = const [],
    this.recordType = '',
  });

  /// ¿Es un lanzamiento corto (sencillo o EP) en vez de un álbum?
  bool get isSingleOrEp => recordType == 'single' || recordType == 'ep';

  /// ¿Es un álbum propiamente dicho? Las recopilaciones cuentan como álbum
  /// para el filtro de la discografía: no son sencillos, y esconderlas del
  /// todo perdería lanzamientos reales.
  bool get isFullAlbum => !isSingleOrEp;

  factory DeezerAlbum.fromJson(Map<String, dynamic> json) {
    final artistMap = json['artist'] as Map<String, dynamic>? ?? {};
    
    List<DeezerTrack> tracksList = [];
    if (json['tracks'] != null && json['tracks']['data'] is List) {
      final tracksData = json['tracks']['data'] as List;
      final albumTitleStr = json['title'] as String? ?? '';
      final coverStr = json['cover_medium'] as String? ?? json['cover_big'] as String? ?? '';
      tracksList = tracksData.map((tJson) {
        // En-rich track json with album data if missing
        final map = Map<String, dynamic>.from(tJson as Map);
        map['album'] ??= {'id': json['id'], 'title': albumTitleStr, 'cover_medium': coverStr};
        if (map['artist'] == null) {
          map['artist'] = artistMap;
        }
        return DeezerTrack.fromJson(map);
      }).toList();
    }

    return DeezerAlbum(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? 'Álbum Sin Título',
      artistName: artistMap['name'] as String? ?? json['artist_name'] as String? ?? 'Artista Desconocido',
      artistId: artistMap['id'] as int? ?? json['artist_id'] as int? ?? 0,
      coverUrl: json['cover_medium'] as String? ??
          json['cover_big'] as String? ??
          json['cover'] as String? ??
          '',
      trackCount: json['nb_tracks'] as int? ?? tracksList.length,
      releaseDate: json['release_date'] as String? ?? '',
      tracks: tracksList,
      recordType: (json['record_type'] as String? ?? '').toLowerCase(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist_name': artistName,
        'artist_id': artistId,
        'cover_medium': coverUrl,
        'nb_tracks': trackCount,
        'release_date': releaseDate,
        'record_type': recordType,
      };
}
