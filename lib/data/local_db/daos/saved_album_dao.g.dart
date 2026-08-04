// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'saved_album_dao.dart';

// ignore_for_file: type=lint
mixin _$SavedAlbumDaoMixin on DatabaseAccessor<SyncoraDatabase> {
  $SavedAlbumsTable get savedAlbums => attachedDatabase.savedAlbums;
  SavedAlbumDaoManager get managers => SavedAlbumDaoManager(this);
}

class SavedAlbumDaoManager {
  final _$SavedAlbumDaoMixin _db;
  SavedAlbumDaoManager(this._db);
  $$SavedAlbumsTableTableManager get savedAlbums =>
      $$SavedAlbumsTableTableManager(_db.attachedDatabase, _db.savedAlbums);
}
