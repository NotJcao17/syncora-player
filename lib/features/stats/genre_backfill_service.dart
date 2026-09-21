import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/apis/deezer_api.dart';
import '../../data/apis/deezer_provider.dart';
import '../../data/local_db/daos/listening_history_dao.dart';
import '../../data/local_db/database_provider.dart';

/// Rellena la columna `genre` de `listening_history` (H-S6).
///
/// **El problema:** las 290 escuchas que había en la base de desarrollo
/// tenían las 290 el género en NULL, así que el top de géneros de
/// Estadísticas estaba estructuralmente vacío. La causa es que nada asignaba
/// nunca `SyncoraTrack.genre`, y no por descuido: Deezer **no devuelve
/// género en ningún endpoint de canción** (`/search`, `/track/{id}`,
/// `/artist/{id}/top`). Solo `/album/{id}` lo trae, en `genres.data[0].name`.
///
/// **La solución:** resolverlo por álbum en segundo plano, no por canción y
/// no durante la reproducción. Un álbum se consulta una única vez en la vida
/// de la instalación y su género se cachea sin caducidad ([AlbumGenreCache]);
/// a partir de ahí, rellenar el género de una escucha no cuesta ninguna
/// petición. Eso sirve por igual para las escuchas nuevas y para las viejas,
/// que es justamente el relleno retroactivo que hacía falta.
///
/// Se ejecuta acotado ([maxAlbumsPerRun]) para que una biblioteca grande no
/// dispare cientos de peticiones de golpe en el arranque: lo que quede se
/// resuelve en las corridas siguientes.
class GenreBackfillService {
  final DeezerApi _deezerApi;
  final ListeningHistoryDao _dao;

  GenreBackfillService({
    required DeezerApi deezerApi,
    required ListeningHistoryDao dao,
  })  : _deezerApi = deezerApi, // ignore: prefer_initializing_formals
        _dao = dao; // ignore: prefer_initializing_formals

  /// Cuántos álbumes nuevos se resuelven por corrida. Cada uno es una
  /// petición a Deezer; el resto espera a la siguiente.
  static const int maxAlbumsPerRun = 25;

  bool _running = false;

  /// Devuelve cuántas filas de historial quedaron con género.
  ///
  /// Nunca lanza: es trabajo de fondo y un fallo de red no debe molestar a
  /// nadie. La guarda de reentrancia evita que dos disparos simultáneos
  /// (arranque + sync) dupliquen las peticiones.
  Future<int> run({int? maxAlbums}) async {
    if (_running) return 0;
    _running = true;
    try {
      var filled = 0;

      // 1) Álbumes ya cacheados cuyas escuchas siguen sin género: gratis, sin
      //    red de por medio. Pasa con cada escucha nueva de un álbum
      //    conocido.
      final pendingAlbums = await _dao.albumIdsMissingGenre(limit: 500);
      if (pendingAlbums.isEmpty) return 0;

      final cached = await _dao.cachedGenres(pendingAlbums.toSet());
      for (final entry in cached.entries) {
        filled += await _dao.applyGenreToAlbum(entry.key, entry.value);
      }

      // 2) Los que faltan, contra Deezer, de a pocos.
      final unknown = pendingAlbums.where((id) => !cached.containsKey(id)).toList();
      final limit = maxAlbums ?? maxAlbumsPerRun;
      for (final albumId in unknown.take(limit)) {
        try {
          final album = await _deezerApi.getAlbum(albumId);
          // Se cachea también el resultado vacío: significa "ya preguntamos y
          // Deezer no tiene género", y sin eso se reintentaría para siempre.
          await _dao.cacheAlbumGenre(albumId, album.genreName);
          filled += await _dao.applyGenreToAlbum(albumId, album.genreName);
        } catch (_) {
          // Álbum inexistente o fallo de red: no se cachea, se reintenta en
          // la próxima corrida.
        }
      }

      return filled;
    } catch (_) {
      return 0;
    } finally {
      _running = false;
    }
  }
}

final genreBackfillServiceProvider = Provider<GenreBackfillService>((ref) {
  return GenreBackfillService(
    deezerApi: ref.watch(deezerApiProvider),
    dao: ref.watch(listeningHistoryDaoProvider),
  );
});
