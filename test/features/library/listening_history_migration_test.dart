import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/apis/deezer_api.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/data/supabase/supabase_history_repository.dart';
import 'package:syncora_player/features/library/import_export/playlist_import_export_service.dart';

/// Bundle de polish post-7.G (hallazgo verificado): la migración local ->
/// cuenta original (7.I.10) solo subía playlists y álbumes guardados, nunca
/// `listening_history` -- Estadísticas partía de cero para cualquier usuario
/// que hubiera acumulado escuchas en modo local antes de crear su cuenta.
/// Doble de [SupabaseHistoryRepository] que simula el "servidor" en memoria
/// para verificar el contenido subido y que un reintento no duplica nada.
class _FakeHistoryRepo extends SupabaseHistoryRepository {
  final List<Map<String, dynamic>> uploaded = [];

  @override
  Future<void> insertListeningHistory({
    required int trackId,
    required DateTime listenedAt,
    int? artistId,
    int? albumId,
    String? genre,
    int? durationListenedMs,
  }) async {
    uploaded.add({
      'track_id': trackId,
      'listened_at': listenedAt,
      'artist_id': artistId,
      'album_id': albumId,
      'genre': genre,
      'duration_listened_ms': durationListenedMs,
    });
  }
}

void main() {
  group('PlaylistImportExportService.migrateLocalListeningHistoryToAccount', () {
    late SyncoraDatabase db;
    late _FakeHistoryRepo fakeRepo;
    late PlaylistImportExportService service;

    setUp(() {
      db = SyncoraDatabase(NativeDatabase.memory());
      fakeRepo = _FakeHistoryRepo();
      service = PlaylistImportExportService(DeezerApi());
    });

    tearDown(() async {
      await db.close();
    });

    test('sube todas las entradas locales sin syncedAt', () async {
      await db.listeningHistoryDao.recordEntry(
        trackId: 101,
        artistId: 1,
        albumId: 1,
        durationListenedMs: 60000,
        genre: 'Rock',
      );
      await db.listeningHistoryDao.recordEntry(
        trackId: 102,
        artistId: 2,
        albumId: 2,
        durationListenedMs: 30000,
      );

      await service.migrateLocalListeningHistoryToAccount(
        listeningHistoryDao: db.listeningHistoryDao,
        supabaseHistoryRepo: fakeRepo,
      );

      expect(fakeRepo.uploaded.length, 2);
      expect(fakeRepo.uploaded.map((e) => e['track_id']), containsAll([101, 102]));
    });

    test('marca las entradas como sincronizadas tras subirlas', () async {
      await db.listeningHistoryDao.recordEntry(
        trackId: 101,
        artistId: 1,
        albumId: 1,
        durationListenedMs: 60000,
      );

      await service.migrateLocalListeningHistoryToAccount(
        listeningHistoryDao: db.listeningHistoryDao,
        supabaseHistoryRepo: fakeRepo,
      );

      final remaining = await db.listeningHistoryDao.getAllUnsyncedHistory();
      expect(remaining, isEmpty);
    });

    test('un reintento no vuelve a subir entradas ya marcadas como sincronizadas', () async {
      await db.listeningHistoryDao.recordEntry(
        trackId: 101,
        artistId: 1,
        albumId: 1,
        durationListenedMs: 60000,
      );

      await service.migrateLocalListeningHistoryToAccount(
        listeningHistoryDao: db.listeningHistoryDao,
        supabaseHistoryRepo: fakeRepo,
      );
      expect(fakeRepo.uploaded.length, 1);

      await service.migrateLocalListeningHistoryToAccount(
        listeningHistoryDao: db.listeningHistoryDao,
        supabaseHistoryRepo: fakeRepo,
      );
      expect(fakeRepo.uploaded.length, 1, reason: 'ya no quedaba nada pendiente de subir');
    });

    test('no hace nada si no hay historial local', () async {
      await service.migrateLocalListeningHistoryToAccount(
        listeningHistoryDao: db.listeningHistoryDao,
        supabaseHistoryRepo: fakeRepo,
      );

      expect(fakeRepo.uploaded, isEmpty);
    });
  });
}
