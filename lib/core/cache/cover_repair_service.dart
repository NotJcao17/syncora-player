import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/apis/deezer_api.dart';
import '../../data/apis/deezer_provider.dart';
import '../../data/local_db/daos/playlist_dao.dart';
import '../../data/local_db/database_provider.dart';
import '../../data/supabase/supabase_playlist_repository.dart';
import '../../data/supabase/supabase_providers.dart';
import '../../features/auth/local_mode_provider.dart';
import '../../features/library/import_export/import_track_matcher.dart';
import '../../features/library/import_export/playlist_import_export_service.dart';
import '../settings/app_settings_store.dart';

/// Repara portadas que Deezer dio de baja (ronda 4).
///
/// Caso real: "Under Pressure" en "Tus me gusta" se quedó sin portada. La
/// versión guardada (track 3098519, recopilación "Best of Bowie") pasó a
/// `readable: false` en Deezer y su portada ahora **redirige a una imagen
/// vacía** (`…/cover/d41d8cd98f00b204e9800998ecf8427e/…`, el MD5 de un
/// archivo vacío). La URL guardada sigue "funcionando", así que nada lo
/// detectaba. El audio no se ve afectado: sale de YouTube por título/artista.
///
/// Una vez por semana, en segundo plano: se revisa cada portada distinta de la
/// biblioteca con una petición `HEAD` sin seguir redirecciones (barata, al
/// CDN, sin tocar la API de Deezer), y para las caídas se busca la misma
/// canción con [ImportTrackMatcher] y se usa su portada, en local y en la nube.
class CoverRepairService {
  CoverRepairService({
    required this.dao,
    required this.api,
    required this.settings,
    this.remote,
  });

  final PlaylistDao dao;
  final DeezerApi api;
  final AppSettingsStore settings;
  final SupabasePlaylistRepository? remote;

  static const _lastRunKey = 'covers.last_repair_ms';
  static const _interval = Duration(days: 7);
  static const _emptyCoverHash = 'd41d8cd98f00b204e9800998ecf8427e';
  static const _concurrency = 6;

  bool _running = false;

  /// Corre si toca (una vez por semana). Devuelve cuántas portadas reparó.
  Future<int> runIfDue() async {
    if (_running || kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) return 0;
    final last = settings.getInt(_lastRunKey);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (last != null && now - last < _interval.inMilliseconds) return 0;
    _running = true;
    try {
      final repaired = await run();
      await settings.setInt(_lastRunKey, now);
      return repaired;
    } catch (_) {
      return 0;
    } finally {
      _running = false;
    }
  }

  Future<int> run() async {
    final covers = await dao.distinctCovers();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final dead = <({int trackId, String title, String artistName, String coverUrl})>[];
    try {
      for (var i = 0; i < covers.length; i += _concurrency) {
        final chunk = covers.skip(i).take(_concurrency).toList();
        final results = await Future.wait(chunk.map((c) => _isDead(client, c.coverUrl)));
        for (var j = 0; j < chunk.length; j++) {
          if (results[j]) dead.add(chunk[j]);
        }
      }
    } finally {
      client.close(force: true);
    }

    var repaired = 0;
    final matcher = ImportTrackMatcher(api);
    for (final c in dead) {
      try {
        final match = await matcher.match(RawImportTrack(title: c.title, artist: c.artistName));
        final newUrl = match?.coverUrl ?? '';
        if (newUrl.isEmpty || newUrl == c.coverUrl || newUrl.contains(_emptyCoverHash)) continue;
        await dao.replaceCoverUrl(c.coverUrl, newUrl);
        try {
          await remote?.replaceCoverUrl(c.coverUrl, newUrl);
        } catch (_) {}
        repaired++;
      } catch (_) {}
    }
    return repaired;
  }

  Future<bool> _isDead(HttpClient client, String url) async {
    if (url.isEmpty) return true;
    if (url.contains(_emptyCoverHash)) return true;
    try {
      final request = await client.headUrl(Uri.parse(url));
      request.followRedirects = false;
      final response = await request.close().timeout(const Duration(seconds: 8));
      await response.drain<void>();
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader) ?? '';
        return location.contains(_emptyCoverHash);
      }
      return response.statusCode == 404;
    } catch (_) {
      // Sin red o timeout: no se sabe, no se toca.
      return false;
    }
  }
}

final coverRepairServiceProvider = Provider<CoverRepairService>((ref) {
  return CoverRepairService(
    dao: ref.watch(playlistDaoProvider),
    api: ref.watch(deezerApiProvider),
    settings: ref.watch(appSettingsStoreProvider),
    remote: ref.watch(localModeProvider) ? null : ref.watch(supabasePlaylistRepositoryProvider),
  );
});
