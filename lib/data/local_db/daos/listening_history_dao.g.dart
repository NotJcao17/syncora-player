// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'listening_history_dao.dart';

// ignore_for_file: type=lint
mixin _$ListeningHistoryDaoMixin on DatabaseAccessor<SyncoraDatabase> {
  $ListeningHistoryTable get listeningHistory =>
      attachedDatabase.listeningHistory;
  ListeningHistoryDaoManager get managers => ListeningHistoryDaoManager(this);
}

class ListeningHistoryDaoManager {
  final _$ListeningHistoryDaoMixin _db;
  ListeningHistoryDaoManager(this._db);
  $$ListeningHistoryTableTableManager get listeningHistory =>
      $$ListeningHistoryTableTableManager(
        _db.attachedDatabase,
        _db.listeningHistory,
      );
}
