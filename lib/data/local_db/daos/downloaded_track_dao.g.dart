// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'downloaded_track_dao.dart';

// ignore_for_file: type=lint
mixin _$DownloadedTrackDaoMixin on DatabaseAccessor<SyncoraDatabase> {
  $DownloadedTracksTable get downloadedTracks =>
      attachedDatabase.downloadedTracks;
  DownloadedTrackDaoManager get managers => DownloadedTrackDaoManager(this);
}

class DownloadedTrackDaoManager {
  final _$DownloadedTrackDaoMixin _db;
  DownloadedTrackDaoManager(this._db);
  $$DownloadedTracksTableTableManager get downloadedTracks =>
      $$DownloadedTracksTableTableManager(
        _db.attachedDatabase,
        _db.downloadedTracks,
      );
}
