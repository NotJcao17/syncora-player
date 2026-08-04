import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'daos/playlist_dao.dart';
import 'daos/saved_album_dao.dart';
import 'daos/listening_history_dao.dart';

part 'syncora_database.g.dart';

// Playlists locales
class Playlists extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get coverUrl => text().nullable()();
  BoolColumn get isLiked => boolean().withDefault(const Constant(false))();
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
  IntColumn get orderIndex => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

// Pistas en playlists — desnormalizada (Documento Maestro §3)
class PlaylistTracks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get playlistId => integer().references(Playlists, #id, onDelete: KeyAction.cascade)();
  IntColumn get trackId => integer()(); // ID de Deezer
  IntColumn get artistId => integer()();
  IntColumn get albumId => integer()();
  TextColumn get title => text()();
  TextColumn get artistName => text()();
  TextColumn get albumName => text()();
  TextColumn get coverUrl => text()();
  IntColumn get durationMs => integer()();
  TextColumn get genre => text().nullable()();
  IntColumn get orderIndex => integer().withDefault(const Constant(0))();
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();
}

// Álbumes guardados
class SavedAlbums extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get albumId => integer().unique()();
  TextColumn get title => text()();
  TextColumn get artistName => text()();
  TextColumn get coverUrl => text()();
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();
}

// Historial de escucha (para Wrapped en Fase 7)
class ListeningHistory extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get trackId => integer()();
  IntColumn get artistId => integer()();
  IntColumn get albumId => integer()();
  TextColumn get genre => text().nullable()();
  DateTimeColumn get listenedAt => dateTime().withDefault(currentDateAndTime)();
  IntColumn get durationListenedMs => integer()();
}

@DriftDatabase(
  tables: [Playlists, PlaylistTracks, SavedAlbums, ListeningHistory],
  daos: [PlaylistDao, SavedAlbumDao, ListeningHistoryDao],
)
class SyncoraDatabase extends _$SyncoraDatabase {
  SyncoraDatabase([QueryExecutor? e]) : super(e ?? _openConnection());

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (m) async {
        await m.createAll();
        // Insert default "Me gusta" playlist if not exists
        await into(playlists).insert(
          PlaylistsCompanion.insert(
            title: 'Tus me gusta',
            description: const Value('Pistas que te han gustado'),
            isLiked: const Value(true),
            isPinned: const Value(true),
            orderIndex: const Value(-1),
          ),
        );
      },
    );
  }
}

QueryExecutor _openConnection() {
  if (kIsWeb) {
    // Pitfall #6: Web bypass to prevent native crashes in Chrome testing
    return NativeDatabase.memory();
  }
  
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'syncora_local.sqlite'));
    
    // Pitfall #5: NativeDatabase.createInBackground for non-blocking I/O
    return NativeDatabase.createInBackground(file);
  });
}
