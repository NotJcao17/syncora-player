import 'dart:io';
import 'package:drift/drift.dart';
import '../syncora_database.dart';

part 'downloaded_track_dao.g.dart';

@DriftAccessor(tables: [DownloadedTracks])
class DownloadedTrackDao extends DatabaseAccessor<SyncoraDatabase> with _$DownloadedTrackDaoMixin {
  DownloadedTrackDao(super.db);

  Future<int> insertOrUpdate(DownloadedTracksCompanion track) async {
    final trackIdVal = track.trackId.value;
    final existing = await getByTrackId(trackIdVal);
    if (existing != null) {
      await (update(downloadedTracks)..where((t) => t.trackId.equals(trackIdVal))).write(track);
      return existing.id;
    } else {
      return into(downloadedTracks).insert(track);
    }
  }


  Future<List<DownloadedTrack>> getAll() async {
    return select(downloadedTracks).get();
  }

  Future<DownloadedTrack?> getByTrackId(int trackId) async {

    return (select(downloadedTracks)..where((t) => t.trackId.equals(trackId))).getSingleOrNull();
  }

  Future<List<DownloadedTrack>> getAllDownloaded() async {
    return (select(downloadedTracks)..where((t) => t.downloadState.equals(2))).get();
  }

  Stream<List<DownloadedTrack>> watchAllDownloaded() {
    return (select(downloadedTracks)..where((t) => t.downloadState.equals(2))).watch();
  }

  /// Estado de descarga de TODAS las pistas en **un solo stream**
  /// (`trackId` -> `downloadState`).
  ///
  /// Ronda 3 bis: cada `TrackTile` abría su propio `watchByTrackId`, o sea un
  /// stream de Drift **por fila visible**, creándose y destruyéndose a cada
  /// scroll. Era una de las dos causas del scroll trabado en las listas de
  /// canciones. Con esta consulta hay un único stream para toda la app y cada
  /// fila se queda con su entrada vía `select`.
  ///
  /// Solo proyecta las dos columnas que la UI necesita: emitir las filas
  /// enteras (título, portada, rutas) por cada cambio de descarga sería
  /// gratuito de más.
  Stream<Map<int, int>> watchDownloadStates() {
    final query = selectOnly(downloadedTracks)
      ..addColumns([downloadedTracks.trackId, downloadedTracks.downloadState]);
    return query.watch().map((rows) => {
          for (final row in rows)
            row.read(downloadedTracks.trackId)!: row.read(downloadedTracks.downloadState)!,
        });
  }

  Stream<DownloadedTrack?> watchByTrackId(int trackId) {
    return (select(downloadedTracks)..where((t) => t.trackId.equals(trackId))).watchSingleOrNull();
  }

  Future<void> deleteByTrackId(int trackId) async {
    final track = await getByTrackId(trackId);
    if (track != null) {
      if (track.localAudioPath.isNotEmpty) {
        try {
          final file = File(track.localAudioPath);
          if (file.existsSync()) {
            file.deleteSync();
          }
        } catch (_) {}
      }
      if (track.localCoverPath != null && track.localCoverPath!.isNotEmpty) {
        try {
          final coverFile = File(track.localCoverPath!);
          if (coverFile.existsSync()) {
            coverFile.deleteSync();
          }
        } catch (_) {}
      }
      await (delete(downloadedTracks)..where((t) => t.trackId.equals(trackId))).go();
    }
  }

  Future<void> deleteAll() async {
    final allTracks = await (select(downloadedTracks)).get();
    for (final track in allTracks) {
      if (track.localAudioPath.isNotEmpty) {
        try {
          final file = File(track.localAudioPath);
          if (file.existsSync()) {
            file.deleteSync();
          }
        } catch (_) {}
      }
      if (track.localCoverPath != null && track.localCoverPath!.isNotEmpty) {
        try {
          final coverFile = File(track.localCoverPath!);
          if (coverFile.existsSync()) {
            coverFile.deleteSync();
          }
        } catch (_) {}
      }
    }
    await delete(downloadedTracks).go();
  }

  Future<int> getTotalSizeBytes() async {
    final allDownloaded = await getAllDownloaded();
    int total = 0;
    for (final t in allDownloaded) {
      total += t.fileSizeBytes;
    }
    return total;
  }
}
