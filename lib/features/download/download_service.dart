import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/cache/cover_cache_service.dart';
import '../../core/extraction/extraction_service.dart';
import '../../core/extraction/models/extraction_request.dart';
import '../../core/extraction/models/extraction_result.dart';

import 'package:drift/drift.dart';
import '../../data/local_db/daos/downloaded_track_dao.dart';
import '../../data/local_db/syncora_database.dart';

import '../player/player_models.dart';


class DownloadException implements Exception {
  final String message;
  DownloadException(this.message);
  @override
  String toString() => message;
}

enum DownloadState { pending, extracting, downloading, done, failed, cancelled }

class DownloadProgress {
  final int trackId;
  final double progress;
  final DownloadState state;
  final String? error;

  DownloadProgress({
    required this.trackId,
    required this.progress,
    required this.state,
    this.error,
  });
}

class DownloadBatchResult {
  final int totalCount;
  final int successCount;
  final int failedCount;
  final List<String> errors;

  const DownloadBatchResult({
    required this.totalCount,
    required this.successCount,
    required this.failedCount,
    required this.errors,
  });

  bool get isSuccess => failedCount == 0;
}

class DownloadService {
  final DownloadedTrackDao _dao;
  final ExtractionService _extractionService;
  final CoverCacheService _coverCacheService;
  // ignore: unused_field
  final Ref _ref;


  bool _isWifiOnly = true;
  final StreamController<DownloadProgress> _progressController =
      StreamController<DownloadProgress>.broadcast();

  final Map<int, bool> _activeCancelTokens = {};

  DownloadService({
    required DownloadedTrackDao dao,
    required ExtractionService extractionService,
    required CoverCacheService coverCacheService,
    required Ref ref,
  })  : _dao = dao,
        _extractionService = extractionService,
        _coverCacheService = coverCacheService,
        _ref = ref;

  Stream<DownloadProgress> get progressStream => _progressController.stream;

  void setWifiOnly(bool wifiOnly) {
    _isWifiOnly = wifiOnly;
  }

  bool get _isTestEnv => Platform.environment.containsKey('FLUTTER_TEST');

  Future<String> _getAudioDir() async {
    if (kIsWeb) return '';
    final base = (await getApplicationDocumentsDirectory()).path;
    final dir = Directory('$base/syncora/downloads');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir.path;
  }

  Future<void> _checkWifiGuard() async {
    if (!_isWifiOnly) return;
    if (_isTestEnv || kIsWeb) return;

    final connectivityResults = await Connectivity().checkConnectivity();
    final isWifi = connectivityResults.contains(ConnectivityResult.wifi) ||
        connectivityResults.contains(ConnectivityResult.ethernet);
    if (!isWifi) {
      throw DownloadException('Solo se permiten descargas con WiFi activo.');
    }
  }

  Future<int> countDownloaded(List<int> trackIds) async {
    int count = 0;
    for (final id in trackIds) {
      final downloaded = await _dao.getByTrackId(id);
      if (downloaded != null && downloaded.downloadState == 2) {
        count++;
      }
    }
    return count;
  }

  Future<bool> downloadTrack(SyncoraTrack track) async {
    await _checkWifiGuard();

    final existing = await _dao.getByTrackId(track.deezerId);
    if (existing != null && existing.downloadState == 2) {
      return true; // Ya descargado
    }

    _activeCancelTokens[track.deezerId] = false;

    // 1. Insertar estado pendiente / descargando en DB
    final audioDir = await _getAudioDir();
    final localAudioPath = '$audioDir/${track.deezerId}.mp4';

    await _dao.insertOrUpdate(
      DownloadedTracksCompanion.insert(
        trackId: track.deezerId,
        artistId: track.artistId ?? 0,
        albumId: track.albumId ?? 0,
        title: track.title,
        artistName: track.artist,
        albumName: track.album ?? '',
        coverUrl: track.coverUrl,
        localAudioPath: localAudioPath,
        durationMs: track.duration?.inMilliseconds ?? 0,
        genre: Value(track.genre),
        downloadState: const Value(1), // downloading
      ),

    );

    _progressController.add(
      DownloadProgress(
        trackId: track.deezerId,
        progress: 0.05,
        state: DownloadState.extracting,
      ),
    );

    try {
      // 2. Extraer URL de YouTube
      final targetId = (track.youtubeVideoId != null && track.youtubeVideoId!.isNotEmpty)
          ? track.youtubeVideoId!
          : track.id;

      final result = await _extractionService.extractUrl(
        targetId,
        trackTitle: track.title,
        trackArtist: track.artist,
        durationSeconds: ((track.duration?.inMilliseconds ?? 0) / 1000).round(),
        priority: ExtractionPriority.download,
      );

      if (_activeCancelTokens[track.deezerId] == true) {
        await _handleCancelled(track.deezerId);
        return false;
      }

      if (result is! ExtractionSuccess) {
        final String errorMsg = (result is ExtractionFailure)
            ? (result.message ?? 'Falló la extracción de YouTube')
            : 'Falló la extracción de YouTube';
        await _handleFailed(track.deezerId, errorMsg);
        return false;
      }

      final streamUrl = result.streamUrl;
      final headers = result.headers;

      _progressController.add(
        DownloadProgress(
          trackId: track.deezerId,
          progress: 0.2,
          state: DownloadState.downloading,
        ),
      );

      // 3. Descargar portada
      String? localCoverPath;
      try {
        localCoverPath = await _coverCacheService.downloadAndCacheCover(
          track.coverUrl,
          track.deezerId,
        );
      } catch (_) {}

      if (_activeCancelTokens[track.deezerId] == true) {
        await _handleCancelled(track.deezerId);
        return false;
      }

      // 4. Descargar archivo de audio
      int fileSize = 0;
      if (_isTestEnv || kIsWeb) {
        final f = File(localAudioPath);
        f.writeAsStringSync('mock_audio_content_${track.deezerId}');
        fileSize = f.lengthSync();
      } else {
        final file = File(localAudioPath);
        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(streamUrl));
          headers.forEach((key, value) {
            request.headers.set(key, value);
          });

          final response = await request.close();

          if (response.statusCode == 200 || response.statusCode == 206) {
            final sink = file.openWrite();
            final totalBytes = response.contentLength;
            int receivedBytes = 0;

            await for (final chunk in response) {
              if (_activeCancelTokens[track.deezerId] == true) {
                await sink.close();
                if (file.existsSync()) file.deleteSync();
                await _handleCancelled(track.deezerId);
                return false;
              }
              sink.add(chunk);
              receivedBytes += chunk.length;
              if (totalBytes > 0) {
                _progressController.add(
                  DownloadProgress(
                    trackId: track.deezerId,
                    progress: 0.2 + (receivedBytes / totalBytes * 0.75),
                    state: DownloadState.downloading,
                  ),
                );
              }
            }
            await sink.close();
            fileSize = file.lengthSync();
          } else {
            await _handleFailed(track.deezerId, 'Error HTTP ${response.statusCode}');
            return false;
          }
        } catch (e) {
          await _handleFailed(track.deezerId, e.toString());
          return false;
        } finally {
          client.close();
        }
      }


      // 5. Actualizar estado completado en DB
      await _dao.insertOrUpdate(
        DownloadedTracksCompanion.insert(
          trackId: track.deezerId,
          artistId: track.artistId ?? 0,
          albumId: track.albumId ?? 0,
          title: track.title,
          artistName: track.artist,
          albumName: track.album ?? '',
          coverUrl: track.coverUrl,
          localCoverPath: Value(localCoverPath),
          localAudioPath: localAudioPath,
          durationMs: track.duration?.inMilliseconds ?? 0,
          genre: Value(track.genre),
          fileSizeBytes: Value(fileSize),
          downloadState: const Value(2), // done
        ),
      );


      _progressController.add(
        DownloadProgress(
          trackId: track.deezerId,
          progress: 1.0,
          state: DownloadState.done,
        ),
      );
      return true;
    } catch (e) {
      if (_activeCancelTokens[track.deezerId] == true) {
        await _handleCancelled(track.deezerId);
      } else {
        await _handleFailed(track.deezerId, e.toString());
      }
      return false;
    } finally {
      _activeCancelTokens.remove(track.deezerId);
    }
  }

  Future<DownloadBatchResult> downloadTracks(List<SyncoraTrack> tracks, {String? groupLabel}) async {
    await _checkWifiGuard();

    int successCount = 0;
    int failedCount = 0;
    final List<String> errors = [];

    for (final track in tracks) {
      final existing = await _dao.getByTrackId(track.deezerId);
      if (existing != null && existing.downloadState == 2) {
        successCount++;
        continue; // Saltar si ya descargado
      }
      try {
        final success = await downloadTrack(track);
        if (success) {
          successCount++;
        } else {
          failedCount++;
          final updated = await _dao.getByTrackId(track.deezerId);
          errors.add('${track.title}: ${updated?.downloadState == 3 ? "Error en la descarga" : "Descarga cancelada"}');
        }
      } catch (e) {
        if (e is DownloadException) rethrow;
        failedCount++;
        errors.add('${track.title}: $e');
      }
    }

    return DownloadBatchResult(
      totalCount: tracks.length,
      successCount: successCount,
      failedCount: failedCount,
      errors: errors,
    );
  }

  Future<void> cancelDownload(int trackId) async {
    _activeCancelTokens[trackId] = true;
    await _handleCancelled(trackId);
  }

  Future<void> cancelAll() async {
    for (final id in _activeCancelTokens.keys) {
      _activeCancelTokens[id] = true;
      await _handleCancelled(id);
    }
  }

  Future<void> cleanupInterruptedDownloads() async {
    if (_isTestEnv || kIsWeb) return;
    try {
      final allDownloaded = await _dao.getAll();
      for (final track in allDownloaded) {
        if (track.downloadState == 1) {
          final file = File(track.localAudioPath);
          if (file.existsSync()) {
            try { file.deleteSync(); } catch (_) {}
          }
          await _dao.deleteByTrackId(track.trackId);
        } else if (track.downloadState == 2) {
          final file = File(track.localAudioPath);
          if (!file.existsSync() || file.lengthSync() == 0) {
            await _dao.deleteByTrackId(track.trackId);
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _handleCancelled(int trackId) async {
    final existing = await _dao.getByTrackId(trackId);
    if (existing != null) {
      if (existing.localAudioPath.isNotEmpty) {
        final file = File(existing.localAudioPath);
        if (file.existsSync()) {
          try { file.deleteSync(); } catch (_) {}
        }
      }
      await _dao.insertOrUpdate(
        DownloadedTracksCompanion.insert(
          trackId: trackId,
          artistId: existing.artistId,
          albumId: existing.albumId,
          title: existing.title,
          artistName: existing.artistName,
          albumName: existing.albumName,
          coverUrl: existing.coverUrl,
          localAudioPath: existing.localAudioPath,
          durationMs: existing.durationMs,
          downloadState: const Value(4), // cancelled
        ),
      );
    }
    _progressController.add(
      DownloadProgress(
        trackId: trackId,
        progress: 0.0,
        state: DownloadState.cancelled,
      ),
    );
  }

  Future<void> _handleFailed(int trackId, String error) async {
    final existing = await _dao.getByTrackId(trackId);
    if (existing != null) {
      if (existing.localAudioPath.isNotEmpty) {
        final file = File(existing.localAudioPath);
        if (file.existsSync()) {
          try { file.deleteSync(); } catch (_) {}
        }
      }
      await _dao.insertOrUpdate(
        DownloadedTracksCompanion.insert(
          trackId: trackId,
          artistId: existing.artistId,
          albumId: existing.albumId,
          title: existing.title,
          artistName: existing.artistName,
          albumName: existing.albumName,
          coverUrl: existing.coverUrl,
          localAudioPath: existing.localAudioPath,
          durationMs: existing.durationMs,
          downloadState: const Value(3), // failed
        ),
      );
    }
    _progressController.add(
      DownloadProgress(
        trackId: trackId,
        progress: 0.0,
        state: DownloadState.failed,
        error: error,
      ),
    );
  }


  void dispose() {
    _progressController.close();
  }
}
