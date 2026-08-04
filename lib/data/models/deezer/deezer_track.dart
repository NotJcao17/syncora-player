import '../../../features/player/player_models.dart';

class DeezerTrack {
  final int id;
  final String title;
  final String artistName;
  final int artistId;
  final String albumTitle;
  final int albumId;
  final String coverUrl;
  final int durationSec;
  final String? previewUrl;

  const DeezerTrack({
    required this.id,
    required this.title,
    required this.artistName,
    required this.artistId,
    required this.albumTitle,
    required this.albumId,
    required this.coverUrl,
    required this.durationSec,
    this.previewUrl,
  });

  factory DeezerTrack.fromJson(Map<String, dynamic> json) {
    final artistMap = json['artist'] as Map<String, dynamic>? ?? {};
    final albumMap = json['album'] as Map<String, dynamic>? ?? {};

    return DeezerTrack(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? json['title_short'] as String? ?? 'Desconocida',
      artistName: artistMap['name'] as String? ?? json['artist_name'] as String? ?? 'Artista Desconocido',
      artistId: artistMap['id'] as int? ?? json['artist_id'] as int? ?? 0,
      albumTitle: albumMap['title'] as String? ?? json['album_title'] as String? ?? '',
      albumId: albumMap['id'] as int? ?? json['album_id'] as int? ?? 0,
      coverUrl: albumMap['cover_medium'] as String? ??
          albumMap['cover_big'] as String? ??
          albumMap['cover'] as String? ??
          json['cover_url'] as String? ??
          '',
      durationSec: json['duration'] as int? ?? 0,
      previewUrl: json['preview'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist_name': artistName,
        'artist_id': artistId,
        'album_title': albumTitle,
        'album_id': albumId,
        'cover_url': coverUrl,
        'duration': durationSec,
        'preview': previewUrl,
      };

  SyncoraTrack toSyncoraTrack() {
    return SyncoraTrack(
      id: id.toString(),
      title: title,
      artist: artistName,
      album: albumTitle,
      duration: Duration(seconds: durationSec),
      artUri: coverUrl.isNotEmpty ? Uri.tryParse(coverUrl) : null,
      previewUrl: previewUrl,
    );
  }
}
