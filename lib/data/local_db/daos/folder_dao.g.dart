// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'folder_dao.dart';

// ignore_for_file: type=lint
mixin _$FolderDaoMixin on DatabaseAccessor<SyncoraDatabase> {
  $FoldersTable get folders => attachedDatabase.folders;
  $PlaylistsTable get playlists => attachedDatabase.playlists;
  FolderDaoManager get managers => FolderDaoManager(this);
}

class FolderDaoManager {
  final _$FolderDaoMixin _db;
  FolderDaoManager(this._db);
  $$FoldersTableTableManager get folders =>
      $$FoldersTableTableManager(_db.attachedDatabase, _db.folders);
  $$PlaylistsTableTableManager get playlists =>
      $$PlaylistsTableTableManager(_db.attachedDatabase, _db.playlists);
}
