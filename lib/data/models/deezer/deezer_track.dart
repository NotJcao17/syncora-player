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
  final List<SyncoraArtistRef> contributorsList;

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
    this.contributorsList = const [],
  });

  factory DeezerTrack.fromJson(Map<String, dynamic> json) {
    final artistMap = json['artist'] as Map<String, dynamic>? ?? {};
    final albumMap = json['album'] as Map<String, dynamic>? ?? {};
    final parsedArtistId = artistMap['id'] as int? ?? json['artist_id'] as int? ?? 0;

    final List<SyncoraArtistRef> contributorsList = [];
    final contributorsRaw = json['contributors'];
    if (contributorsRaw is List) {
      for (final item in contributorsRaw) {
        if (item is Map) {
          final rawId = item['id'];
          final rawName = item['name'];
          final id = rawId is int ? rawId : (rawId != null ? int.tryParse(rawId.toString()) ?? 0 : 0);
          final name = rawName is String ? rawName : '';
          if (name.isNotEmpty) {
            contributorsList.add(SyncoraArtistRef(id: id, name: name));
          }
        }
      }
    }

    String resolvedArtistName = '';
    if (contributorsList.isNotEmpty) {
      resolvedArtistName = contributorsList.map((c) => c.name).join(', ');
    } else {
      resolvedArtistName = artistMap['name'] as String? ?? json['artist_name'] as String? ?? 'Artista Desconocido';
    }

    if (contributorsList.isEmpty) {
      if (resolvedArtistName.contains(', ')) {
        final names = resolvedArtistName.split(', ');
        for (int i = 0; i < names.length; i++) {
          contributorsList.add(SyncoraArtistRef(
            id: i == 0 ? parsedArtistId : 0,
            name: names[i].trim(),
          ));
        }
      } else if (parsedArtistId != 0 || resolvedArtistName.isNotEmpty) {
        contributorsList.add(SyncoraArtistRef(id: parsedArtistId, name: resolvedArtistName));
      }
    }

    return DeezerTrack(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? json['title_short'] as String? ?? 'Desconocida',
      artistName: resolvedArtistName,
      artistId: parsedArtistId,
      albumTitle: albumMap['title'] as String? ?? json['album_title'] as String? ?? '',
      albumId: albumMap['id'] as int? ?? json['album_id'] as int? ?? 0,
      coverUrl: albumMap['cover_medium'] as String? ??
          albumMap['cover_big'] as String? ??
          albumMap['cover'] as String? ??
          json['cover_url'] as String? ??
          '',
      durationSec: json['duration'] as int? ?? 0,
      previewUrl: json['preview'] as String?,
      contributorsList: contributorsList,
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
      artists: contributorsList,
      artistId: artistId,
      album: albumTitle,
      albumId: albumId,
      duration: Duration(seconds: durationSec),
      artUri: coverUrl.isNotEmpty ? Uri.tryParse(coverUrl) : null,
      previewUrl: previewUrl,
    );
  }
}

