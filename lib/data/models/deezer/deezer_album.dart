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

  const DeezerAlbum({
    required this.id,
    required this.title,
    required this.artistName,
    required this.artistId,
    required this.coverUrl,
    required this.trackCount,
    required this.releaseDate,
    this.tracks = const [],
  });

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
      };
}
