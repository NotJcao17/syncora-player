import 'package:flutter/foundation.dart';

/// Pista del dominio de Syncora, independiente de `audio_service`.
///
/// `audio_service` (Android) no soporta Windows, por lo que no podemos usar
/// `MediaItem` como modelo compartido. En su lugar usamos [SyncoraTrack] en
/// toda la lógica, y cada adaptador de controles del SO lo traduce a su tipo
/// nativo (`MediaItem` en Android, `MusicMetadata` en Windows).
@immutable
class SyncoraTrack {
  /// ID lógico de la pista. Para esta fase (Fase 2) es el `videoId` de YouTube.
  final String id;

  final String title;
  final String artist;
  final String? album;
  final Duration? duration;

  /// URL de la portada (red). Se reenvía a la notificación / SMTC.
  final Uri? artUri;

  /// Indica si la pista es spoken-word/podcast (habilita Skip Silence agresivo
  /// en Android, Pitfall #7).
  final bool isSpokenWord;

  const SyncoraTrack({
    required this.id,
    required this.title,
    this.artist = '',
    this.album,
    this.duration,
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
    Uri? artUri,
    bool? isSpokenWord,
  }) {
    return SyncoraTrack(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      artUri: artUri ?? this.artUri,
      isSpokenWord: isSpokenWord ?? this.isSpokenWord,
    );
  }
}

/// Modo de repetición expuesto al reproductor.
enum SyncoraRepeatMode { off, one, all }
