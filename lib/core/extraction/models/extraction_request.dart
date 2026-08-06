enum ExtractionPriority { streaming, download }

/// Petición que viaja del Main Isolate al ExtractionIsolate
class ExtractionRequest {
  final String videoId;
  final String requestId; // UUID o ID único para correlacionar respuesta
  final ExtractionPriority priority; // P0=streaming, P1=download
  final String? trackTitle;
  final String? trackArtist;
  final int? durationSeconds;

  const ExtractionRequest({
    required this.videoId,
    required this.requestId,
    this.priority = ExtractionPriority.streaming,
    this.trackTitle,
    this.trackArtist,
    this.durationSeconds,
  });

  Map<String, dynamic> toJson() => {
        'videoId': videoId,
        'requestId': requestId,
        'priority': priority.name,
        'trackTitle': trackTitle,
        'trackArtist': trackArtist,
        'durationSeconds': durationSeconds,
      };

  factory ExtractionRequest.fromJson(Map<String, dynamic> json) =>
      ExtractionRequest(
        videoId: json['videoId'] as String,
        requestId: json['requestId'] as String,
        priority: ExtractionPriority.values.firstWhere(
          (e) => e.name == json['priority'],
          orElse: () => ExtractionPriority.streaming,
        ),
        trackTitle: json['trackTitle'] as String?,
        trackArtist: json['trackArtist'] as String?,
        durationSeconds: json['durationSeconds'] as int?,
      );
}
