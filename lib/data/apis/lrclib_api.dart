import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class LrcLine {
  final Duration timestamp;
  final String text;

  const LrcLine({required this.timestamp, required this.text});
}

class LRCLibResult {
  final String? plainLyrics;
  final String? syncedLyrics;
  final List<LrcLine> lines;

  const LRCLibResult({
    this.plainLyrics,
    this.syncedLyrics,
    this.lines = const [],
  });

  bool get hasSynced => lines.isNotEmpty && syncedLyrics != null && syncedLyrics!.isNotEmpty;
  bool get hasPlain => plainLyrics != null && plainLyrics!.isNotEmpty;
  bool get isEmpty => !hasSynced && !hasPlain;

  /// Helper to parse standard LRC string [mm:ss.xx] into LrcLines
  static List<LrcLine> parseLrc(String? lrcContent) {
    if (lrcContent == null || lrcContent.trim().isEmpty) return [];

    final List<LrcLine> result = [];
    final regExp = RegExp(r'^\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)$');

    for (final rawLine in lrcContent.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final match = regExp.firstMatch(line);
      if (match != null) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final millisStr = match.group(3)!;
        final millis = int.parse(millisStr.padRight(3, '0').substring(0, 3));
        final text = match.group(4)!.trim();

        final timestamp = Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: millis,
        );

        result.add(LrcLine(timestamp: timestamp, text: text));
      }
    }

    result.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return result;
  }
}

class LRCLibApi {
  /// Intentos por petición ante un 429/503 de LRCLib (el primero incluido).
  static const maxAttempts = 4;

  final Dio _dio;
  final Future<void> Function(Duration) _sleep;
  final Map<String, LRCLibResult?> _cache = {};

  LRCLibApi({Dio? dio, Future<void> Function(Duration)? sleep})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://lrclib.net/api',
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 5),
              // LRCLib pide que los clientes se identifiquen.
              headers: {'User-Agent': 'Syncora Player (https://syncoraplayer.app)'},
            )),
        _sleep = sleep ?? Future<void>.delayed;

  /// Solo se cachea una respuesta definitiva (letra encontrada, o `/get` y
  /// `/search` coinciden en que no existe). Un fallo temporal (429, timeout,
  /// sin red) dejaba la canción sin letra hasta reiniciar la app; ahora se
  /// vuelve a pedir la próxima vez que se abra la letra.
  Future<LRCLibResult?> getLyrics({
    required String cacheKey,
    required String trackTitle,
    required String artistName,
    required int durationSec,
  }) async {
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey];
    }

    var transientFailure = false;

    try {
      final response = await _getWithRetry(
        '/get',
        {
          'track_name': trackTitle,
          'artist_name': artistName,
          if (durationSec > 0) 'duration': durationSec,
        },
      );

      if (response.data != null && response.data is Map) {
        final result = _toResult(Map<String, dynamic>.from(response.data as Map));
        _cache[cacheKey] = result;
        return result;
      }
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) transientFailure = true;
    } catch (_) {
      transientFailure = true;
    }

    // Fallback: búsqueda difusa por título y artista en /search
    try {
      final searchRes = await _getWithRetry('/search', {'q': '$trackTitle $artistName'});

      if (searchRes.data != null && searchRes.data is List && (searchRes.data as List).isNotEmpty) {
        final result = _toResult(Map<String, dynamic>.from((searchRes.data as List).first as Map));
        _cache[cacheKey] = result;
        return result;
      }
    } catch (e) {
      transientFailure = true;
      if (kDebugMode) {
        print('LRCLibApi search error: $e');
      }
    }

    if (!transientFailure) _cache[cacheKey] = null;
    return null;
  }

  static LRCLibResult _toResult(Map<String, dynamic> data) {
    final synced = data['syncedLyrics'] as String?;
    return LRCLibResult(
      plainLyrics: data['plainLyrics'] as String?,
      syncedLyrics: synced,
      lines: LRCLibResult.parseLrc(synced),
    );
  }

  /// LRCLib limita peticiones (429 con `Retry-After: 1`) y suele responder
  /// tras unos segundos; la espera crece en cada intento aunque diga 1 s.
  Future<Response<dynamic>> _getWithRetry(String path, Map<String, dynamic> query) async {
    for (var attempt = 1;; attempt++) {
      try {
        return await _dio.get(path, queryParameters: query);
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if ((status != 429 && status != 503) || attempt >= maxAttempts) rethrow;
        final retryAfter = int.tryParse(e.response?.headers.value('retry-after') ?? '') ?? 1;
        await _sleep(Duration(seconds: retryAfter.clamp(attempt, 5)));
      }
    }
  }
}
