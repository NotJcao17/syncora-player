// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'stats_metadata_cache_dao.dart';

// ignore_for_file: type=lint
mixin _$StatsMetadataCacheDaoMixin on DatabaseAccessor<SyncoraDatabase> {
  $StatsMetadataCacheTable get statsMetadataCache =>
      attachedDatabase.statsMetadataCache;
  StatsMetadataCacheDaoManager get managers =>
      StatsMetadataCacheDaoManager(this);
}

class StatsMetadataCacheDaoManager {
  final _$StatsMetadataCacheDaoMixin _db;
  StatsMetadataCacheDaoManager(this._db);
  $$StatsMetadataCacheTableTableManager get statsMetadataCache =>
      $$StatsMetadataCacheTableTableManager(
        _db.attachedDatabase,
        _db.statsMetadataCache,
      );
}
