import 'deezer_track.dart';

class DeezerPlaylist {
  final int id;
  final String title;
  final String pictureUrl;
  final int nbTracks;
  final String userName;

  /// Solo llega desde `/playlist/{id}`; vacío en los listados
  /// (`/chart/0/playlists`, `/user/{id}/playlists`).
  final String description;

  /// Duración total en segundos (0 si el endpoint no la trae).
  final int durationSec;

  /// Pistas de la playlist. Solo vienen en `/playlist/{id}`.
  final List<DeezerTrack> tracks;

  const DeezerPlaylist({
    required this.id,
    required this.title,
    required this.pictureUrl,
    required this.nbTracks,
    required this.userName,
    this.description = '',
    this.durationSec = 0,
    this.tracks = const [],
  });

  factory DeezerPlaylist.fromJson(Map<String, dynamic> json) {
    final userMap = json['user'] as Map<String, dynamic>? ??
        json['creator'] as Map<String, dynamic>? ??
        const {};

    final tracks = <DeezerTrack>[];
    final tracksSection = json['tracks'];
    if (tracksSection is Map && tracksSection['data'] is List) {
      for (final item in tracksSection['data'] as List) {
        if (item is! Map) continue;
        // Mismo filtro de calidad que el resto de la app: nada de podcasts ni
        // interludios de menos de un minuto.
        if ((item['duration'] as int? ?? 0) <= 60) continue;
        if (item['type'] == 'podcast') continue;
        tracks.add(DeezerTrack.fromJson(Map<String, dynamic>.from(item)));
      }
    }

    return DeezerPlaylist(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? 'Playlist sin título',
      pictureUrl: json['picture_medium'] as String? ??
          json['picture_big'] as String? ??
          json['picture_xl'] as String? ??
          json['picture'] as String? ??
          json['picture_url'] as String? ??
          '',
      nbTracks: json['nb_tracks'] as int? ?? tracks.length,
      userName: userMap['name'] as String? ?? json['user_name'] as String? ?? 'Deezer',
      description: json['description'] as String? ?? '',
      durationSec: json['duration'] as int? ?? 0,
      tracks: tracks,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'picture_url': pictureUrl,
        'nb_tracks': nbTracks,
        'user_name': userName,
        'description': description,
        'duration': durationSec,
        if (tracks.isNotEmpty) 'tracks': {'data': tracks.map((t) => t.toJson()).toList()},
      };
}
