import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/data/apis/deezer_api.dart';
import 'package:syncora_player/data/local_db/syncora_database.dart';
import 'package:syncora_player/data/models/deezer/deezer_track.dart';
import 'package:syncora_player/data/supabase/supabase_playlist_repository.dart';
import 'package:syncora_player/features/library/import_export/playlist_import_export_service.dart';
import 'package:syncora_player/features/player/player_models.dart';

/// Fase 7.F.1, punto 3 -- cubre la secuencia canónica de inserción extraída
/// a `PlaylistImportExportService.createPlaylistWithMatchedTracks`, ahora
/// compartida por la importación CSV/TXT y "Crear playlist con IA".
///
/// `SupabasePlaylistRepository` se auto-desactiva en entorno de test
/// (`Platform.environment.containsKey('FLUTTER_TEST')`, ver el propio
/// archivo) -- por eso este test cubre el camino "sin red"/"remoto
/// indisponible": la playlist queda local-only (sin `remoteId`), que es
/// exactamente el estado seguro que el comentario original documentaba.
DeezerTrack _track(int id, {String title = 'Song', String artist = 'Artist'}) {
  return DeezerTrack(
    id: id,
    title: title,
    artistName: artist,
    artistId: id * 10,
    albumTitle: 'Album',
    albumId: id * 100,
    coverUrl: 'https://cover.example/$id.jpg',
    durationSec: 200,
    // 2 colaboradores para que `resolveDeezerTrackContributors` no dispare
    // ninguna llamada de red (solo lo hace si `contributorsList.length <= 1`).
    contributorsList: [
      SyncoraArtistRef(id: id * 10, name: artist),
      SyncoraArtistRef(id: id * 10 + 1, name: 'Feat $id'),
    ],
  );
}

void main() {
  late SyncoraDatabase db;
  late PlaylistImportExportService service;

  setUp(() {
    db = SyncoraDatabase(NativeDatabase.memory());
    service = PlaylistImportExportService(DeezerApi());
  });

  tearDown(() async {
    await db.close();
  });

  group('createPlaylistWithMatchedTracks', () {
    test('crea la playlist local con todas las pistas matcheadas, en orden', () async {
      final tracks = [
        _track(1, title: 'A'),
        _track(2, title: 'B'),
        _track(3, title: 'C'),
      ];

      final playlistId = await service.createPlaylistWithMatchedTracks(
        title: 'Mi playlist IA',
        description: 'Generada con IA',
        matchedTracks: tracks,
        dao: db.playlistDao,
        deezerApi: DeezerApi(),
        supabaseRepo: SupabasePlaylistRepository(),
      );

      final playlist = await db.playlistDao.getPlaylistById(playlistId);
      expect(playlist, isNotNull);
      expect(playlist!.title, equals('Mi playlist IA'));
      expect(playlist.description, equals('Generada con IA'));

      final storedTracks = await db.playlistDao.getTracksOrdered(playlistId);
      expect(storedTracks.length, equals(3));
      expect(storedTracks.map((t) => t.title).toList(), equals(['A', 'B', 'C']));
    });

    test('sin backend remoto disponible (entorno de test), la playlist queda local-only sin remoteId', () async {
      final playlistId = await service.createPlaylistWithMatchedTracks(
        title: 'Local only',
        matchedTracks: [_track(1)],
        dao: db.playlistDao,
        deezerApi: DeezerApi(),
        supabaseRepo: SupabasePlaylistRepository(),
      );

      final playlist = await db.playlistDao.getPlaylistById(playlistId);
      expect(playlist!.remoteId, isNull);
    });

    test('lista de pistas matcheadas vacía crea la playlist igual, sin pistas', () async {
      final playlistId = await service.createPlaylistWithMatchedTracks(
        title: 'Vacía',
        matchedTracks: const [],
        dao: db.playlistDao,
        deezerApi: DeezerApi(),
        supabaseRepo: SupabasePlaylistRepository(),
      );

      final storedTracks = await db.playlistDao.getTracksOrdered(playlistId);
      expect(storedTracks, isEmpty);
    });
  });
}
