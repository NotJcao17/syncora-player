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
  final Dio _dio;
  final Map<String, LRCLibResult?> _cache = {};

  LRCLibApi({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://lrclib.net/api',
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 5),
            ));

  Future<LRCLibResult?> getLyrics({
    required String cacheKey,
    required String trackTitle,
    required String artistName,
    required int durationSec,
  }) async {
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey];
    }

    try {
      final response = await _dio.get(
        '/get',
        queryParameters: {
          'track_name': trackTitle,
          'artist_name': artistName,
          if (durationSec > 0) 'duration': durationSec,
        },
      );

      if (response.data != null && response.data is Map) {
        final data = Map<String, dynamic>.from(response.data as Map);
        final plain = data['plainLyrics'] as String?;
        final synced = data['syncedLyrics'] as String?;
        final lines = LRCLibResult.parseLrc(synced);

        final result = LRCLibResult(
          plainLyrics: plain,
          syncedLyrics: synced,
          lines: lines,
        );

        _cache[cacheKey] = result;
        return result;
      }
    } catch (_) {}

    // Fallback: búsqueda difusa por título y artista en /search
    try {
      final searchRes = await _dio.get(
        '/search',
        queryParameters: {
          'q': '$trackTitle $artistName',
        },
      );

      if (searchRes.data != null && searchRes.data is List && (searchRes.data as List).isNotEmpty) {
        final firstMatch = Map<String, dynamic>.from((searchRes.data as List).first as Map);
        final plain = firstMatch['plainLyrics'] as String?;
        final synced = firstMatch['syncedLyrics'] as String?;
        final lines = LRCLibResult.parseLrc(synced);

        final result = LRCLibResult(
          plainLyrics: plain,
          syncedLyrics: synced,
          lines: lines,
        );

        _cache[cacheKey] = result;
        return result;
      }
    } catch (e) {
      if (kDebugMode) {
        print('LRCLibApi search error: $e');
      }
    }

    _cache[cacheKey] = null;
    return null;
  }
}
