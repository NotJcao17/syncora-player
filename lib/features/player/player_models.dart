import 'package:flutter/foundation.dart';

@immutable
class SyncoraArtistRef {
  final int id;
  final String name;
  const SyncoraArtistRef({required this.id, required this.name});
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

  /// Indica si la pista es spoken-word/podcast (habilita Skip Silence agresivo en Android).
  final String? previewUrl;
  final bool isSpokenWord;

  const SyncoraTrack({
    required this.id,
    required this.title,
    this._artist = '',
    this.artists = const [],
    this.artistId,
    this.album,
    this.albumId,
    this.duration,
    this.youtubeVideoId,
    this.artUri,
    this.previewUrl,
    this.isSpokenWord = false,
  });

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
    );
  }
}

/// Modo de repetición expuesto al reproductor.
enum SyncoraRepeatMode { off, one, all }

