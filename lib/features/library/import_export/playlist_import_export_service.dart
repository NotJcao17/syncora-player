import 'dart:async';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';

import '../../../data/apis/deezer_api.dart';
import '../../../data/models/deezer/deezer_track.dart';

class RawImportTrack {
  final String title;
  final String artist;
  final String? album;
  final String? isrc;

  const RawImportTrack({
    required this.title,
    required this.artist,
    this.album,
    this.isrc,
  });

  @override
  String toString() => '$artist - $title';
}

class ImportProgress {
  final int current;
  final int total;
  final String currentTrackName;

  const ImportProgress({
    required this.current,
    required this.total,
    required this.currentTrackName,
  });

  double get ratio => total == 0 ? 0 : current / total;
}

class ImportResult {
  final List<DeezerTrack> matchedTracks;
  final List<RawImportTrack> unmatchedTracks;

  const ImportResult({
    required this.matchedTracks,
    required this.unmatchedTracks,
  });

  int get total => matchedTracks.length + unmatchedTracks.length;
}

class PlaylistImportExportService {
  final DeezerApi _deezerApi;

  PlaylistImportExportService(this._deezerApi);

  /// Parse CSV or TXT file contents into a list of RawImportTrack objects
  List<RawImportTrack> parseFileContent(String fileContent) {
    final List<RawImportTrack> results = [];
    final lines = fileContent.split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return results;

    // Check if it's CSV
    if (fileContent.contains(',') || fileContent.contains('\t')) {
      try {
        final rows = csv.decode(fileContent.replaceAll('\r\n', '\n'));

        if (rows.isNotEmpty) {
          // Check header row
          final firstRowStr = rows.first.map((e) => e.toString().toLowerCase().trim()).toList();
          int titleIdx = -1;
          int artistIdx = -1;
          int albumIdx = -1;
          int isrcIdx = -1;

          for (int i = 0; i < firstRowStr.length; i++) {
            final col = firstRowStr[i];
            if (col == 'name' || col == 'title' || col == 'track name' || col == 'song') {
              titleIdx = i;
            } else if (col == 'artist' || col == 'artist name') {
              artistIdx = i;
            } else if (col == 'album' || col == 'album name') {
              albumIdx = i;
            } else if (col == 'isrc') {
              isrcIdx = i;
            }
          }

          int startRow = 0;
          if (titleIdx != -1 || artistIdx != -1) {
            // Header detected
            startRow = 1;
          } else {
            // Default column assumptions: col 0 = title or artist, col 1 = artist or title
            titleIdx = 0;
            artistIdx = 1;
            if (firstRowStr.length > 2) albumIdx = 2;
          }

          for (int i = startRow; i < rows.length; i++) {
            final row = rows[i];
            if (row.isEmpty) continue;

            final titleStr = (titleIdx >= 0 && titleIdx < row.length) ? row[titleIdx].toString().trim() : '';
            final artistStr = (artistIdx >= 0 && artistIdx < row.length) ? row[artistIdx].toString().trim() : '';
            final albumStr = (albumIdx >= 0 && albumIdx < row.length) ? row[albumIdx].toString().trim() : null;
            final isrcStr = (isrcIdx >= 0 && isrcIdx < row.length) ? row[isrcIdx].toString().trim() : null;

            if (titleStr.isNotEmpty || artistStr.isNotEmpty) {
              results.add(RawImportTrack(
                title: titleStr.isEmpty ? 'Desconocida' : titleStr,
                artist: artistStr,
                album: albumStr,
                isrc: isrcStr,
              ));
            }
          }

          if (results.isNotEmpty) return results;
        }
      } catch (e) {
        if (kDebugMode) print('CSV parsing failed, falling back to line parsing: $e');
      }
    }

    // Fallback: Plain text line parsing ("Artist - Title" or "Title")
    for (final line in lines) {
      final cleanLine = line.trim();
      if (cleanLine.isEmpty) continue;

      if (cleanLine.contains(' - ')) {
        final parts = cleanLine.split(' - ');
        final artist = parts[0].trim();
        final title = parts.sublist(1).join(' - ').trim();
        results.add(RawImportTrack(title: title, artist: artist));
      } else {
        results.add(RawImportTrack(title: cleanLine, artist: ''));
      }
    }

    return results;
  }

  /// Process raw tracks sequentially against Deezer API with rate limiting
  Stream<ImportProgress> processImport({
    required List<RawImportTrack> rawTracks,
    required List<DeezerTrack> outMatched,
    required List<RawImportTrack> outUnmatched,
  }) async* {
    for (int i = 0; i < rawTracks.length; i++) {
      final item = rawTracks[i];
      yield ImportProgress(
        current: i + 1,
        total: rawTracks.length,
        currentTrackName: item.toString(),
      );

      try {
        final query = item.artist.isNotEmpty ? '${item.artist} ${item.title}' : item.title;
        final searchRes = await _deezerApi.search(query, type: DeezerSearchType.track);

        if (searchRes.tracks.isNotEmpty) {
          outMatched.add(searchRes.tracks.first);
        } else {
          outUnmatched.add(item);
        }
      } catch (e) {
        outUnmatched.add(item);
      }

      // Pitfall #4 & #22: 200ms pause between sequential requests
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  /// Export tracks to CSV string format: title,artist,album,duration_ms
  String exportToCsv(List<Map<String, dynamic>> tracksData) {
    final List<List<dynamic>> rows = [
      ['title', 'artist', 'album', 'duration_ms']
    ];

    for (final track in tracksData) {
      rows.add([
        track['title'] ?? '',
        track['artist'] ?? '',
        track['album'] ?? '',
        track['duration_ms'] ?? 0,
      ]);
    }

    return csv.encode(rows);
  }
}
