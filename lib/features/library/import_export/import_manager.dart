import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/utils/connectivity_service.dart';
import '../../../core/utils/contributor_resolver.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/local_db/syncora_database.dart';
import '../../../data/models/deezer/deezer_track.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../auth/local_mode_provider.dart';
import '../../player/player_models.dart';
import 'playlist_import_export_service.dart';

/// Importación de playlists en segundo plano (ronda 4, H-R4-11).
///
/// Antes la importación vivía dentro de un diálogo modal: bloqueaba la app
/// durante minutos (1000 canciones ≈ 15 min), cerrar la app lo perdía todo y
/// no había forma de cancelarla. Ahora:
///
/// - **La playlist se crea al empezar** y se va llenando por bloques; el
///   usuario puede seguir usando la app y verla crecer.
/// - **Es reanudable:** el trabajo (pistas del archivo + por dónde va) se
///   guarda en disco tras cada bloque. Si la app se cierra, al volver a
///   abrirla sigue donde se quedó.
/// - **Es cancelable:** detener conservando lo importado, o cancelar y borrar
///   la playlist.
/// - **Es más rápida:** los bloques se resuelven de forma concurrente (el
///   `RateLimiter` de Deezer sigue mandando), sin la pausa fija de 200 ms, y
///   las pistas se insertan en una sola transacción por bloque.
///
/// Invariante con la nube (misma que D-8 de `createPlaylistWithMatchedTracks`,
/// con otra forma): cada bloque se sube a Supabase **antes** de insertarse en
/// Drift, así que la nube siempre tiene al menos lo mismo que el dispositivo y
/// un sync que coincida con la importación nunca poda pistas locales. Si el
/// sync ya trajo parte del bloque, esas pistas se saltan al insertar.
enum ImportJobStatus { running, paused, completed, cancelled }

class ImportJob {
  const ImportJob({
    required this.id,
    required this.title,
    required this.playlistId,
    required this.remotePlaylistId,
    required this.rawTracks,
    required this.nextIndex,
    required this.matchedCount,
    required this.unmatched,
    required this.status,
    this.pauseReason,
  });

  final String id;
  final String title;
  final int playlistId;
  final String? remotePlaylistId;
  final List<RawImportTrack> rawTracks;

  /// Índice de la siguiente pista del archivo sin procesar.
  final int nextIndex;
  final int matchedCount;
  final List<RawImportTrack> unmatched;
  final ImportJobStatus status;

  /// Por qué está en pausa (sin conexión, la nube rechazó el bloque...).
  final String? pauseReason;

  int get total => rawTracks.length;
  double get ratio => total == 0 ? 1 : nextIndex / total;
  bool get isActive => status == ImportJobStatus.running || status == ImportJobStatus.paused;

  ImportJob copyWith({
    int? nextIndex,
    int? matchedCount,
    List<RawImportTrack>? unmatched,
    ImportJobStatus? status,
    String? pauseReason,
    bool clearPauseReason = false,
  }) {
    return ImportJob(
      id: id,
      title: title,
      playlistId: playlistId,
      remotePlaylistId: remotePlaylistId,
      rawTracks: rawTracks,
      nextIndex: nextIndex ?? this.nextIndex,
      matchedCount: matchedCount ?? this.matchedCount,
      unmatched: unmatched ?? this.unmatched,
      status: status ?? this.status,
      pauseReason: clearPauseReason ? null : (pauseReason ?? this.pauseReason),
    );
  }

  static Map<String, dynamic> _rawToJson(RawImportTrack t) => {
        'title': t.title,
        'artist': t.artist,
        if (t.album != null) 'album': t.album,
        if (t.isrc != null) 'isrc': t.isrc,
        if (t.durationMs != null) 'durationMs': t.durationMs,
      };

  static RawImportTrack _rawFromJson(Map<String, dynamic> j) => RawImportTrack(
        title: j['title'] as String? ?? '',
        artist: j['artist'] as String? ?? '',
        album: j['album'] as String?,
        isrc: j['isrc'] as String?,
        durationMs: (j['durationMs'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'playlistId': playlistId,
        'remotePlaylistId': remotePlaylistId,
        'rawTracks': rawTracks.map(_rawToJson).toList(),
        'nextIndex': nextIndex,
        'matchedCount': matchedCount,
        'unmatched': unmatched.map(_rawToJson).toList(),
        'status': status.name,
        'pauseReason': pauseReason,
      };

  static ImportJob fromJson(Map<String, dynamic> j) => ImportJob(
        id: j['id'] as String,
        title: j['title'] as String? ?? 'Importación',
        playlistId: (j['playlistId'] as num).toInt(),
        remotePlaylistId: j['remotePlaylistId'] as String?,
        rawTracks: [
          for (final t in (j['rawTracks'] as List? ?? const [])) _rawFromJson(Map<String, dynamic>.from(t as Map)),
        ],
        nextIndex: (j['nextIndex'] as num?)?.toInt() ?? 0,
        matchedCount: (j['matchedCount'] as num?)?.toInt() ?? 0,
        unmatched: [
          for (final t in (j['unmatched'] as List? ?? const [])) _rawFromJson(Map<String, dynamic>.from(t as Map)),
        ],
        status: ImportJobStatus.values.firstWhere(
          (s) => s.name == j['status'],
          orElse: () => ImportJobStatus.paused,
        ),
        pauseReason: j['pauseReason'] as String?,
      );
}

/// Persistencia de los trabajos de importación. Uno por archivo JSON en
/// `syncora/imports/`, escritos de forma atómica (temporal + rename).
class ImportJobStore {
  const ImportJobStore();

  Future<Directory?> _dir() async {
    if (kIsWeb) return null;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/syncora/imports');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<List<ImportJob>> loadAll() async {
    try {
      final dir = await _dir();
      if (dir == null) return [];
      final jobs = <ImportJob>[];
      for (final entity in dir.listSync()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final raw = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
          jobs.add(ImportJob.fromJson(raw));
        } catch (_) {
          // Archivo a medio escribir o corrupto: no se puede reanudar.
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }
      return jobs;
    } catch (_) {
      return [];
    }
  }

  Future<void> save(ImportJob job) async {
    try {
      final dir = await _dir();
      if (dir == null) return;
      final tmp = File('${dir.path}/${job.id}.json.tmp');
      await tmp.writeAsString(jsonEncode(job.toJson()), flush: true);
      await tmp.rename('${dir.path}/${job.id}.json');
    } catch (_) {}
  }

  Future<void> delete(String id) async {
    try {
      final dir = await _dir();
      if (dir == null) return;
      final f = File('${dir.path}/$id.json');
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}

/// Sin disco: para tests.
class InMemoryImportJobStore extends ImportJobStore {
  InMemoryImportJobStore();
  final Map<String, ImportJob> jobs = {};

  @override
  Future<List<ImportJob>> loadAll() async => jobs.values.toList();

  @override
  Future<void> save(ImportJob job) async => jobs[job.id] = job;

  @override
  Future<void> delete(String id) async => jobs.remove(id);
}

final importJobStoreProvider = Provider<ImportJobStore>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return InMemoryImportJobStore();
  return const ImportJobStore();
});

class ImportManager extends Notifier<List<ImportJob>> {
  /// Pistas por bloque: se resuelven a la vez, se suben a la nube en una sola
  /// petición y se insertan en una sola transacción.
  static const int chunkSize = 10;

  final Set<String> _running = {};
  bool _loaded = false;

  @override
  List<ImportJob> build() {
    Future.microtask(_loadAndResume);
    // Lo que se pausó por falta de conexión sigue solo al recuperarla.
    ref.listen(isConnectedProvider, (previous, next) {
      if (next.value != true || previous?.value == true) return;
      for (final job in state) {
        if (job.status == ImportJobStatus.paused && job.pauseReason == _offlineReason) resume(job.id);
      }
    });
    return const [];
  }

  static const _offlineReason = 'Sin conexión';

  ImportJobStore get _store => ref.read(importJobStoreProvider);

  Future<void> _loadAndResume() async {
    if (_loaded) return;
    _loaded = true;
    final stored = await _store.loadAll();
    if (stored.isEmpty || !ref.mounted) return;
    final known = {for (final j in state) j.id};
    state = [...state, ...stored.where((j) => !known.contains(j.id))];
    // Lo que quedó "en curso" al cerrarse la app se reanuda solo.
    for (final job in stored) {
      if (job.status == ImportJobStatus.running) unawaited(_run(job.id));
    }
  }

  ImportJob? _job(String id) {
    for (final j in state) {
      if (j.id == id) return j;
    }
    return null;
  }

  void _put(ImportJob job) {
    state = [
      for (final j in state)
        if (j.id == job.id) job else j,
    ];
    unawaited(_store.save(job));
  }

  /// Crea la playlist y empieza a llenarla. Devuelve el id local de la
  /// playlist para poder navegar a ella.
  Future<int> startImport({
    required String title,
    String? description,
    required List<RawImportTrack> rawTracks,
  }) async {
    final dao = ref.read(playlistDaoProvider);
    String? remoteId;
    if (!ref.read(localModeProvider)) {
      try {
        final created = await ref
            .read(supabasePlaylistRepositoryProvider)
            .createPlaylist(title: title, description: description);
        remoteId = created['id']?.toString();
      } catch (_) {
        // Sin nube: la playlist queda solo en local, un estado seguro que
        // ningún sync toca (igual que antes de esta ronda).
      }
    }
    final playlistId = await dao.createPlaylist(title: title, description: description, remoteId: remoteId);

    final job = ImportJob(
      id: '${DateTime.now().microsecondsSinceEpoch}_$playlistId',
      title: title,
      playlistId: playlistId,
      remotePlaylistId: remoteId,
      rawTracks: List.unmodifiable(rawTracks),
      nextIndex: 0,
      matchedCount: 0,
      unmatched: const [],
      status: ImportJobStatus.running,
    );
    state = [...state, job];
    await _store.save(job);
    unawaited(_run(job.id));
    return playlistId;
  }

  void resume(String id) {
    final job = _job(id);
    if (job == null || job.status != ImportJobStatus.paused) return;
    _put(job.copyWith(status: ImportJobStatus.running, clearPauseReason: true));
    unawaited(_run(id));
  }

  /// Detiene la importación. Con [deletePlaylist], borra además la playlist
  /// (local y remota); si no, se queda con lo que ya se importó.
  Future<void> cancel(String id, {required bool deletePlaylist}) async {
    final job = _job(id);
    if (job == null) return;
    state = [
      for (final j in state)
        if (j.id == id) j.copyWith(status: ImportJobStatus.cancelled) else j,
    ];
    await _store.delete(id);
    if (deletePlaylist) {
      final remoteId = job.remotePlaylistId;
      if (remoteId != null) {
        try {
          await ref.read(supabasePlaylistRepositoryProvider).deletePlaylist(remoteId);
        } catch (_) {}
      }
      await ref.read(playlistDaoProvider).deletePlaylist(job.playlistId);
    }
    // Las canceladas no se muestran: lo que quedó está en la biblioteca.
    state = state.where((j) => j.id != id).toList();
  }

  /// Quita de la vista un trabajo ya terminado.
  void dismiss(String id) {
    state = state.where((j) => j.id != id).toList();
    unawaited(_store.delete(id));
  }

  bool _stillRunning(String id) => ref.mounted && _job(id)?.status == ImportJobStatus.running;

  Future<void> _run(String id) async {
    if (!_running.add(id)) return;
    try {
      while (true) {
        if (!ref.mounted) return;
        final job = _job(id);
        if (job == null || job.status != ImportJobStatus.running) return;

        if (job.nextIndex >= job.total) {
          _put(job.copyWith(status: ImportJobStatus.completed));
          return;
        }

        final dao = ref.read(playlistDaoProvider);
        if (await dao.getPlaylistById(job.playlistId) == null) {
          // El usuario borró la playlist a mitad: no hay dónde seguir.
          await cancel(id, deletePlaylist: false);
          return;
        }

        if (!(ref.read(isConnectedProvider).value ?? true)) {
          _put(job.copyWith(status: ImportJobStatus.paused, pauseReason: _offlineReason));
          return;
        }

        final end = (job.nextIndex + chunkSize).clamp(0, job.total);
        final chunk = job.rawTracks.sublist(job.nextIndex, end);
        final service = PlaylistImportExportService(ref.read(deezerApiProvider));
        final matched = <DeezerTrack>[];
        final unmatched = <RawImportTrack>[];
        await for (final _ in service.processImport(
          rawTracks: chunk,
          outMatched: matched,
          outUnmatched: unmatched,
        )) {}
        if (!_stillRunning(id)) return;

        final ok = await _insertChunk(job, matched);
        if (!_stillRunning(id)) return;
        if (!ok) {
          _put(job.copyWith(
            status: ImportJobStatus.paused,
            pauseReason: 'No se pudo guardar en la nube',
          ));
          return;
        }

        if (!ref.mounted) return;
        final latest = _job(id);
        if (latest == null) return;
        _put(latest.copyWith(
          nextIndex: end,
          matchedCount: latest.matchedCount + matched.length,
          unmatched: [...latest.unmatched, ...unmatched],
        ));
      }
    } catch (e) {
      if (!ref.mounted) return;
      final job = _job(id);
      if (job != null && job.status == ImportJobStatus.running) {
        _put(job.copyWith(status: ImportJobStatus.paused, pauseReason: 'Error inesperado'));
      }
    } finally {
      _running.remove(id);
    }
  }

  /// Sube el bloque a la nube (un reintento) y después lo inserta en local,
  /// saltando lo que ya esté en la playlist. `false` si la nube no lo aceptó.
  Future<bool> _insertChunk(ImportJob job, List<DeezerTrack> matched) async {
    if (matched.isEmpty) return true;
    final dao = ref.read(playlistDaoProvider);
    final deezerApi = ref.read(deezerApiProvider);

    final existing = (await dao.getTracksOrdered(job.playlistId)).map((t) => t.trackId).toSet();
    final fresh = <DeezerTrack>[];
    for (final t in matched) {
      if (existing.add(t.id)) fresh.add(t);
    }
    if (fresh.isEmpty) return true;

    final contributors = await Future.wait(fresh.map((t) async {
      try {
        return await resolveDeezerTrackContributors(deezerApi, t);
      } catch (_) {
        return t.contributorsList;
      }
    }));

    final remoteId = job.remotePlaylistId;
    if (remoteId != null) {
      final payload = [
        for (var i = 0; i < fresh.length; i++)
          {
            'track_id': fresh[i].id,
            'artist_id': fresh[i].artistId,
            'album_id': fresh[i].albumId,
            'title': fresh[i].title,
            'artist_name': fresh[i].artistName,
            'album_name': fresh[i].albumTitle,
            'cover_url': fresh[i].coverUrl,
            'duration_ms': fresh[i].durationSec * 1000,
            if (contributors[i].isNotEmpty) 'contributors_json': SyncoraArtistRef.encodeList(contributors[i]),
          },
      ];
      final repo = ref.read(supabasePlaylistRepositoryProvider);
      var uploaded = false;
      for (var attempt = 0; attempt < 2 && !uploaded; attempt++) {
        try {
          if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 2));
          await repo.addTracksToPlaylist(remoteId, payload);
          uploaded = true;
        } catch (_) {}
      }
      if (!uploaded) return false;
    }

    // Lo que un sync pudo haber bajado mientras tanto no se duplica.
    final afterUpload = (await dao.getTracksOrdered(job.playlistId)).map((t) => t.trackId).toSet();
    final rows = <PlaylistTracksCompanion>[];
    for (var i = 0; i < fresh.length; i++) {
      final t = fresh[i];
      if (afterUpload.contains(t.id)) continue;
      rows.add(PlaylistTracksCompanion.insert(
        playlistId: job.playlistId,
        trackId: t.id,
        artistId: t.artistId,
        albumId: t.albumId,
        title: t.title,
        artistName: t.artistName,
        albumName: t.albumTitle,
        coverUrl: t.coverUrl,
        durationMs: t.durationSec * 1000,
        contributorsJson: Value(SyncoraArtistRef.encodeList(contributors[i])),
      ));
    }
    await dao.appendTracksBatch(job.playlistId, rows);
    return true;
  }
}

final importManagerProvider = NotifierProvider<ImportManager, List<ImportJob>>(ImportManager.new);
