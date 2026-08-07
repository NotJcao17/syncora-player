class DeezerPlaylist {
  final int id;
  final String title;
  final String pictureUrl;
  final int nbTracks;
  final String userName;

  const DeezerPlaylist({
    required this.id,
    required this.title,
    required this.pictureUrl,
    required this.nbTracks,
    required this.userName,
  });

  factory DeezerPlaylist.fromJson(Map<String, dynamic> json) {
    final userMap = json['user'] as Map<String, dynamic>? ?? {};
    return DeezerPlaylist(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? 'Playlist sin título',
      pictureUrl: json['picture_medium'] as String? ??
          json['picture_big'] as String? ??
          json['picture'] as String? ??
          '',
      nbTracks: json['nb_tracks'] as int? ?? 0,
      userName: userMap['name'] as String? ?? 'Deezer',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'picture_url': pictureUrl,
        'nb_tracks': nbTracks,
        'user_name': userName,
      };
}
