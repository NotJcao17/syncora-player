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
  final int? rank;

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
    this.rank,
  });

  factory DeezerTrack.fromJson(Map<String, dynamic> json) {
    final artistMap = json['artist'] as Map<String, dynamic>? ?? {};
    final albumMap = json['album'] as Map<String, dynamic>? ?? {};
    final parsedArtistId = artistMap['id'] as int? ?? json['artist_id'] as int? ?? 0;

    final List<SyncoraArtistRef> contributorsList = [];
    final contributorsRaw = json['contributors'];
    if (contributorsRaw is List) {
      // Deezer repite al mismo colaborador con roles distintos (ej. Bruno
      // Mars aparece como "Main" y "Featured" con el mismo id en
      // /track/{id}) — confirmado contra la API en vivo. Deduplicar por id
      // cuando hay uno real; si falta (id=0), por nombre, para no fusionar
      // por accidente a dos colaboradores distintos sin id.
      final seenKeys = <String>{};
      for (final item in contributorsRaw) {
        if (item is Map) {
          final rawId = item['id'];
          final rawName = item['name'];
          final id = rawId is int ? rawId : (rawId != null ? int.tryParse(rawId.toString()) ?? 0 : 0);
          final name = rawName is String ? rawName : '';
          final key = id != 0 ? 'id:$id' : 'name:${name.toLowerCase()}';
          if (name.isNotEmpty && seenKeys.add(key)) {
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
      rank: json['rank'] as int?,
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
        'rank': rank,
      };

  /// Devuelve una copia con `contributorsList` (y `artistName` derivado de esa
  /// lista) reemplazados — usado para enriquecer resultados de búsqueda que
  /// llegaron con un solo artista (`/search` no trae `contributors`) con el
  /// detalle completo obtenido de `/track/{id}`.
  DeezerTrack withContributors(List<SyncoraArtistRef> contributors) {
    if (contributors.isEmpty) return this;
    return DeezerTrack(
      id: id,
      title: title,
      artistName: contributors.map((c) => c.name).join(', '),
      artistId: artistId,
      albumTitle: albumTitle,
      albumId: albumId,
      coverUrl: coverUrl,
      durationSec: durationSec,
      previewUrl: previewUrl,
      contributorsList: contributors,
      rank: rank,
    );
  }

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


