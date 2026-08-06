class DeezerArtist {
  final int id;
  final String name;
  final String pictureUrl;
  final int nbFan;

  const DeezerArtist({
    required this.id,
    required this.name,
    required this.pictureUrl,
    required this.nbFan,
  });

  factory DeezerArtist.fromJson(Map<String, dynamic> json) {
    return DeezerArtist(
      id: json['id'] as int? ?? 0,
      name: json['name'] as String? ?? 'Artista Desconocido',
      pictureUrl: json['picture_xl'] as String? ??
          json['picture_big'] as String? ??
          json['picture_medium'] as String? ??
          json['picture'] as String? ??
          '',
      nbFan: json['nb_fan'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'picture_medium': pictureUrl,
        'nb_fan': nbFan,
      };
}
