import 'package:flutter/foundation.dart';

/// Pista del dominio de Syncora, independiente de `audio_service`.
@immutable
class SyncoraTrack {
  /// ID lógico de la pista. Para esta fase es el `videoId` de YouTube o ID de Deezer.
  final String id;

  final String title;
  final String artist;
  final String? album;
  final Duration? duration;
  final String? youtubeVideoId;

  /// URL de la portada (red). Se reenvía a la notificación / SMTC.
  final Uri? artUri;

  /// Helper de conveniencia para obtener la URL de portada como String.
  String get coverUrl => artUri?.toString() ?? '';

  /// Indica si la pista es spoken-word/podcast (habilita Skip Silence agresivo en Android).
  final bool isSpokenWord;

  const SyncoraTrack({
    required this.id,
    required this.title,
    this.artist = '',
    this.album,
    this.duration,
    this.youtubeVideoId,
    this.artUri,
    this.isSpokenWord = false,
  });

  factory SyncoraTrack.fromVideoId({
    required String videoId,
    String? title,
    String? artist,
  }) {
    return SyncoraTrack(
      id: videoId,
      youtubeVideoId: videoId,
      title: title ?? 'Video $videoId',
      artist: artist ?? 'YouTube',
    );
  }

  SyncoraTrack copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    String? youtubeVideoId,
    Uri? artUri,
    String? coverUrl,
    bool? isSpokenWord,
  }) {
    return SyncoraTrack(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      youtubeVideoId: youtubeVideoId ?? this.youtubeVideoId,
      artUri: artUri ?? (coverUrl != null ? Uri.tryParse(coverUrl) : this.artUri),
      isSpokenWord: isSpokenWord ?? this.isSpokenWord,
    );
  }
}

/// Modo de repetición expuesto al reproductor.
enum SyncoraRepeatMode { off, one, all }
