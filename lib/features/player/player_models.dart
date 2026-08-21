import 'dart:convert';
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

  /// Serializa la lista de colaboradores para persistirla en BD (columna `contributorsJson`).
  /// Devuelve `null` cuando hay 0 o 1 artista: en ese caso `artistName` ya basta y no vale
  /// la pena guardar el JSON.
  static String? encodeList(List<SyncoraArtistRef> artists) {
    if (artists.length <= 1) return null;
    return jsonEncode(artists.map((a) => a.toJson()).toList());
  }

  /// Inverso de [encodeList]. Devuelve lista vacía si `raw` es nulo, vacío o inválido —
  /// nunca lanza, para no romper la lectura de filas antiguas sin este dato.
  static List<SyncoraArtistRef> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded
          .map((e) => SyncoraArtistRef.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return const [];
    }
  }
}

/// Pista del dominio de Syncora, independiente de `audio_service`.
@immutable
class SyncoraTrack {
  /// ID lógico de la pista. Para esta fase es el `videoId` de YouTube o ID de Deezer.
  final String id;

  int get deezerId => int.tryParse(id) ?? id.hashCode.abs();

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

/// De qué cola provino una pista: la manual (agregada explícitamente por el
/// usuario, FIFO, D-2) o la automática (regenerable desde el contexto activo).
enum QueueOrigin { manual, auto }

/// Entrada de la pila de historial de reproducción (D-3): registra tanto la
/// pista como de qué cola provino, para que "anterior" pueda devolverla a su
/// cola de origen intacta.
@immutable
class HistoryEntry {
  final SyncoraTrack track;
  final QueueOrigin origin;
  const HistoryEntry(this.track, this.origin);

  Map<String, dynamic> toJson() => {
        'track': track.toJson(),
        'origin': origin.name,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    final originName = json['origin'] as String? ?? 'auto';
    return HistoryEntry(
      SyncoraTrack.fromJson(json['track'] as Map<String, dynamic>),
      QueueOrigin.values.firstWhere(
        (e) => e.name == originName,
        orElse: () => QueueOrigin.auto,
      ),
    );
  }
}

/// Tipo de aviso puntual que el controlador expone a la UI (Fase 7.C +
/// hallazgo H-6). Todos son **solo de sesión** (D-21): viven en
/// [SyncoraPlayerState], nunca se persisten en [PlayerSessionData], y se
/// resetean solos al reiniciar la app junto con el resto del estado inicial.
enum PlayerNoticeKind {
  /// Auto-skip lógico (7.C.1): la pista no se pudo resolver en el catálogo
  /// (`ExtractionError.notFound`/`unknownError`) estando online, y el
  /// controlador ya saltó automáticamente a la siguiente. Toast:
  /// "{título} no disponible — saltada".
  logicalSkip,

  /// Guard de cascada (7.C.3): 3 fallos lógicos seguidos, sin ningún éxito
  /// de reproducción entre medio, detuvieron el auto-skip (no sigue
  /// saltando solo) y dejaron el motor pausado.
  cascadeGuard,

  /// Error persistente (403/red) tras 1 reintento (H-6): la pausa inmediata
  /// ya funcionaba desde la Fase 1 (guard anti-bucle), pero el aviso visual
  /// que la acompaña nunca llegó a conectarse a ningún widget. Mensaje
  /// distinto al de [logicalSkip] — nunca dice "no disponible — saltada",
  /// porque acá no hubo ningún skip, solo una pausa.
  persistentError,
}

/// Aviso puntual del reproductor para la UI (Fase 7.C + H-6). Cada instancia
/// representa UN evento — [id] es monotónico dentro de la vida del
/// controlador (ver `_noticeCounter` en `SyncoraPlayerController`) para que
/// la UI pueda distinguir "evento nuevo" de "el mismo estado, solo un
/// rebuild", incluso en el caso poco probable de que dos eventos distintos
/// terminen con el mismo [message].
@immutable
class PlayerNotice {
  final int id;
  final PlayerNoticeKind kind;
  final String message;

  /// Solo relevante para [PlayerNoticeKind.logicalSkip]: título de la pista
  /// saltada, por si la UI quiere usarlo aparte del texto ya armado en
  /// [message].
  final String? trackTitle;

  const PlayerNotice({
    required this.id,
    required this.kind,
    required this.message,
    this.trackTitle,
  });
}
