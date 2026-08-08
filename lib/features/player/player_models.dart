import 'package:flutter/foundation.dart';

@immutable
class SyncoraArtistRef {
  final int id;
  final String name;
  const SyncoraArtistRef({required this.id, required this.name});

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
      };

  factory SyncoraArtistRef.fromJson(Map<String, dynamic> json) => SyncoraArtistRef(
        id: json['id'] as int? ?? 0,
        name: json['name'] as String? ?? '',
      );
}

/// Pista del dominio de Syncora, independiente de `audio_service`.
@immutable
class SyncoraTrack {
  /// ID lógico de la pista. Para esta fase es el `videoId` de YouTube o ID de Deezer.
  final String id;

  final String title;
  final String _artist;

  String get artist {
    if (artists.isNotEmpty) {
      return artists.map((a) => a.name).join(', ');
    }
    return _artist;
  }

  final List<SyncoraArtistRef> artists;
  final int? artistId;
  final String? album;
  final int? albumId;
  final Duration? duration;
  final String? youtubeVideoId;

  /// URL de la portada (red). Se reenvía a la notificación / SMTC.
  final Uri? artUri;

  /// Helper de conveniencia para obtener la URL de portada como String.
  String get coverUrl => artUri?.toString() ?? '';

  final String? previewUrl;
  final bool isSpokenWord;
  final String? genre;

  const SyncoraTrack({
    required this.id,
    required this.title,
    String artist = '',
    this.artists = const [],
    this.artistId,
    this.album,
    this.albumId,
    this.duration,
    this.youtubeVideoId,
    this.artUri,
    this.previewUrl,
    this.isSpokenWord = false,
    this.genre,
  }) : _artist = artist; // ignore: prefer_initializing_formals

  factory SyncoraTrack.fromVideoId({
    required String videoId,
    String? title,
    String? artist,
    List<SyncoraArtistRef> artists = const [],
  }) {
    return SyncoraTrack(
      id: videoId,
      youtubeVideoId: videoId,
      title: title ?? 'Video $videoId',
      artist: artist ?? 'YouTube',
      artists: artists,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': _artist,
        'artists': artists.map((a) => a.toJson()).toList(),
        'artistId': artistId,
        'album': album,
        'albumId': albumId,
        'durationMs': duration?.inMilliseconds,
        'youtubeVideoId': youtubeVideoId,
        'artUri': artUri?.toString(),
        'previewUrl': previewUrl,
        'isSpokenWord': isSpokenWord,
        'genre': genre,
      };

  factory SyncoraTrack.fromJson(Map<String, dynamic> json) {
    final artUriStr = json['artUri'] as String?;
    return SyncoraTrack(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      artists: (json['artists'] as List<dynamic>?)
              ?.map((a) => SyncoraArtistRef.fromJson(a as Map<String, dynamic>))
              .toList() ??
          const [],
      artistId: json['artistId'] as int?,
      album: json['album'] as String?,
      albumId: json['albumId'] as int?,
      duration: json['durationMs'] != null ? Duration(milliseconds: json['durationMs'] as int) : null,
      youtubeVideoId: json['youtubeVideoId'] as String?,
      artUri: artUriStr != null && artUriStr.isNotEmpty ? Uri.tryParse(artUriStr) : null,
      previewUrl: json['previewUrl'] as String?,
      isSpokenWord: json['isSpokenWord'] as bool? ?? false,
      genre: json['genre'] as String?,
    );
  }

  SyncoraTrack copyWith({
    String? id,
    String? title,
    String? artist,
    List<SyncoraArtistRef>? artists,
    int? artistId,
    String? album,
    int? albumId,
    Duration? duration,
    String? youtubeVideoId,
    Uri? artUri,
    String? coverUrl,
    String? previewUrl,
    bool? isSpokenWord,
    String? genre,
  }) {
    return SyncoraTrack(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? _artist,
      artists: artists ?? this.artists,
      artistId: artistId ?? this.artistId,
      album: album ?? this.album,
      albumId: albumId ?? this.albumId,
      duration: duration ?? this.duration,
      youtubeVideoId: youtubeVideoId ?? this.youtubeVideoId,
      artUri: artUri ?? (coverUrl != null ? Uri.tryParse(coverUrl) : this.artUri),
      previewUrl: previewUrl ?? this.previewUrl,
      isSpokenWord: isSpokenWord ?? this.isSpokenWord,
      genre: genre ?? this.genre,
    );
  }
}

/// Modo de repetición expuesto al reproductor.
enum SyncoraRepeatMode { off, one, all }
