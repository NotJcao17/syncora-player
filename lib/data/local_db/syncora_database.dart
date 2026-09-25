import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'daos/playlist_dao.dart';
import 'daos/saved_album_dao.dart';
import 'daos/listening_history_dao.dart';
import 'daos/downloaded_track_dao.dart';
import 'daos/stats_metadata_cache_dao.dart';

part 'syncora_database.g.dart';

// Playlists locales
class Playlists extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get remoteId => text().nullable()();
  TextColumn get title => text()();
  TextColumn get description => text().nullable()();
  TextColumn get coverUrl => text().nullable()();
  BoolColumn get isPublic => boolean().withDefault(const Constant(false))();
  BoolColumn get isLiked => boolean().withDefault(const Constant(false))();
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
  IntColumn get orderIndex => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  /// Última vez que se empezó a reproducir esta playlist (ronda 3, D1).
  ///
  /// **Solo local, a propósito.** No tiene columna en Supabase ni viaja en el
  /// sync: "lo que escuché más recientemente" es razonablemente un dato del
  /// dispositivo, y mantenerlo local evita sumar otra migración a la lista de
  /// pasos manuales pendientes del proyecto. `null` = nunca reproducida desde
  /// este dispositivo, que es lo que ordena al final de la vista "escuchadas
  /// recientemente".
  DateTimeColumn get lastPlayedAt => dateTime().nullable()();

  /// De dónde salió esta playlist, cuando no la creó el usuario a mano.
  ///
  /// Formatos: `deezer_playlist:1234` para una copia de una playlist de
  /// Deezer, y `mix:<clave del mix>` para un mix guardado o generado.
  ///
  /// Sirve para dos cosas: que el botón de guardar pueda mostrarse ya en
  /// estado "Guardada" (antes no había forma de saber que la copia existía,
  /// así que el usuario volvía a pulsarlo y la playlist se duplicaba en su
  /// biblioteca), y para localizar el "On Repeat" generado.
  ///
  /// Solo local, como `lastPlayedAt`: no tiene columna en Supabase.
  TextColumn get sourceRef => text().nullable()();

  /// ¿La mantiene la app, en vez del usuario?
  ///
  /// Hoy solo "On Repeat": existe siempre, se regenera sola cada semana y no
  /// se edita a mano, igual que "Tus me gusta". No viaja a Supabase — se
  /// deriva del historial local de cada dispositivo.
  BoolColumn get isGenerated => boolean().withDefault(const Constant(false))();
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
  // JSON de List<{id,name}> con todos los colaboradores (Deezer `contributors`).
  // Nullable: solo se llena cuando se pudo resolver más de 1 artista al guardar.
  TextColumn get contributorsJson => text().nullable()();
}

// Álbumes guardados
class SavedAlbums extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get albumId => integer().unique()();
  TextColumn get title => text()();
  TextColumn get artistName => text()();
  TextColumn get coverUrl => text()();
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();

  /// Última vez que se reprodujo este álbum desde este dispositivo (ronda 3
  /// bis). Mismo criterio que `Playlists.lastPlayedAt`: **solo local**, no
  /// viaja al sync. Alimenta el orden "escuchados recientemente" de
  /// Biblioteca, que ahora también aplica a la sección de Álbumes.
  DateTimeColumn get lastPlayedAt => dateTime().nullable()();
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
  // Fase 7.0.1: marca de sincronización con Supabase. NULL = pendiente de subir.
  // Se rellena con la fecha/hora local tras un `insert`/`upsert` exitoso en
  // `SyncService._syncListeningHistoryInternal()`, para no re-enviar (y
  // duplicar) filas ya sincronizadas en cada sync.
  DateTimeColumn get syncedAt => dateTime().nullable()();
  // H-S3: true cuando la fila no se grabo en ESTE aparato, sino que la bajo
  // `SyncService._pullRemoteHistory()` desde la nube.
  //
  // El dedupe de escuchas (`findRecentEntryForTrack`) reutiliza la fila de una
  // escucha reciente de la misma pista en vez de crear otra. Sin esta marca
  // tambien reutilizaba filas de OTRO dispositivo: si escuchabas un tema en el
  // PC y lo ponias en el movil cinco minutos despues, el movil editaba la fila
  // del PC y subia la suma de ambas. Una fila quedaba inflada, la otra escucha
  // desaparecia, y el resultado dependia del orden en que hubieran corrido los
  // syncs en cada aparato.
  BoolColumn get fromRemote => boolean().withDefault(const Constant(false))();
}

/// Genero de cada album, resuelto una sola vez contra `/album/{id}` (H-S6).
///
/// Deezer no devuelve genero en ningun endpoint de CANCION (`/search`,
/// `/track/{id}`, `/artist/{id}/top`): solo `/album/{id}` lo trae, en
/// `genres.data[0].name`. Pedirlo en cada escucha seria una peticion extra
/// por cancion reproducida, asi que se resuelve por album y se cachea sin
/// caducidad -- el genero de un album no cambia.
///
/// Una fila con [genre] vacio significa "ya se consulto y Deezer no tiene
/// genero para este album": tambien se cachea, para no reintentarlo siempre.
class AlbumGenreCache extends Table {
  IntColumn get albumId => integer()();
  TextColumn get genre => text()();
  DateTimeColumn get fetchedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {albumId};
}

// Pistas descargadas localmente (Fase 6 — Device-specific)
class DownloadedTracks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get trackId => integer().unique()();
  IntColumn get artistId => integer()();
  IntColumn get albumId => integer()();
  TextColumn get title => text()();
  TextColumn get artistName => text()();
  TextColumn get albumName => text()();
  TextColumn get coverUrl => text()();
  TextColumn get localCoverPath => text().nullable()();
  TextColumn get localAudioPath => text()();
  IntColumn get durationMs => integer()();
  TextColumn get genre => text().nullable()();
  IntColumn get fileSizeBytes => integer().withDefault(const Constant(0))();
  IntColumn get downloadState => integer().withDefault(const Constant(0))();
  // 0=pending, 1=downloading, 2=done, 3=failed, 4=cancelled
  DateTimeColumn get downloadedAt => dateTime().withDefault(currentDateAndTime)();
  // JSON de List<{id,name}> con todos los colaboradores (Deezer `contributors`).
  // Nullable: solo se llena cuando se pudo resolver más de 1 artista al guardar.
  TextColumn get contributorsJson => text().nullable()();
}

// Caché de nombre/portada de artistas y canciones resueltos para
// Estadísticas -- ver `StatsMetadataCacheDao` para el motivo (evitar golpear
// Deezer en vivo por cada carga de la pantalla de Estadísticas).
class StatsMetadataCache extends Table {
  TextColumn get entityType => text()(); // 'artist' | 'track'
  IntColumn get entityId => integer()();
  TextColumn get primaryName => text()(); // nombre del artista o título de la canción
  TextColumn get secondaryName => text().nullable()(); // null para artista; nombre del artista para canción
  TextColumn get coverUrl => text()();
  DateTimeColumn get cachedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {entityType, entityId};
}

@DriftDatabase(
  tables: [
    Playlists,
    PlaylistTracks,
    SavedAlbums,
    ListeningHistory,
    DownloadedTracks,
    StatsMetadataCache,
    AlbumGenreCache,
  ],
  daos: [PlaylistDao, SavedAlbumDao, ListeningHistoryDao, DownloadedTrackDao, StatsMetadataCacheDao],
)
class SyncoraDatabase extends _$SyncoraDatabase {
  SyncoraDatabase([QueryExecutor? e]) : super(e ?? _openConnection());

  @override
  int get schemaVersion => 12;

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
            orderIndex: const Value(-1),
          ),
        );
      },
      onUpgrade: (m, from, to) async {
        if (from < 2) {
          await m.addColumn(playlists, playlists.remoteId);
          await m.addColumn(playlists, playlists.isPublic);
        }
        if (from < 3) {
          await m.createTable(downloadedTracks);
        }
        if (from < 4) {
          await m.addColumn(playlistTracks, playlistTracks.contributorsJson);
          await m.addColumn(downloadedTracks, downloadedTracks.contributorsJson);
        }
        if (from < 5) {
          await m.addColumn(listeningHistory, listeningHistory.syncedAt);
        }
        if (from < 6) {
          await m.createTable(statsMetadataCache);
        }
        if (from < 7) {
          await m.addColumn(playlists, playlists.lastPlayedAt);
        }
        if (from < 8) {
          await m.addColumn(savedAlbums, savedAlbums.lastPlayedAt);
        }
        if (from < 9) {
          await m.addColumn(playlists, playlists.sourceRef);
          await m.addColumn(playlists, playlists.isGenerated);
        }
        if (from < 10) {
          await m.addColumn(listeningHistory, listeningHistory.fromRemote);
        }
        if (from < 11) {
          await m.createTable(albumGenreCache);
        }
        if (from < 12) {
          // Ronda 4 (H-R4-8): "Tus me gusta" y "On Repeat" nacían fijadas, y
          // como la biblioteca pone las fijadas primero quedaban siempre
          // arriba, ignorando el orden elegido. Ahora fijar es una decisión
          // del usuario, así que se desfijan una única vez.
          await customStatement(
            'UPDATE playlists SET is_pinned = 0 WHERE is_liked = 1 OR is_generated = 1',
          );
        }
      },
    );
  }
}

QueryExecutor _openConnection() {
  if (kIsWeb) {
    // Pitfall #6: Web bypass to prevent native crashes in Chrome testing
    return NativeDatabase.memory();
  }

  // Bug real (pruebas manuales, post-Fase 7): `weeklyStatsProvider`/
  // `monthlyStatsProvider` (7.G) pasaron de `FutureProvider` a
  // `StreamProvider` sobre un `.watch()` de Drift -- en tests de widget que
  // arman la app completa (`widget_test.dart`, `app_router_test.dart`), esa
  // suscripción sobre la conexión real (sin `closeStreamsSynchronously`)
  // dejaba un `Timer` pendiente al cerrar el árbol de widgets, y
  // `flutter_test` falla el test entero por eso (invariante estricta de
  // `TestWidgetsFlutterBinding`). Ya era un gotcha conocido del proyecto en
  // tests puntuales que arman su propia `SyncoraDatabase` (ver
  // `ai_create_queue_sheet_test.dart`) -- acá se resuelve en la fuente para
  // que cualquier test que arme la app completa lo herede gratis, en vez de
  // tener que repetir el mismo workaround en cada archivo de test nuevo.
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    return DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true);
  }

  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'syncora_local.sqlite'));
    
    // Pitfall #5: NativeDatabase.createInBackground for non-blocking I/O
    return NativeDatabase.createInBackground(file);
  });
}
