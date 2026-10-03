import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Caché en disco de las portadas (ronda 4).
///
/// `CachedNetworkImage` usa por defecto `DefaultCacheManager`, que guarda como
/// máximo **200 imágenes**. Una sola playlist de 600 canciones ya la desborda:
/// cada imagen nueva expulsaba otra, así que al reiniciar la app las portadas
/// volvían a descargarse (el "se cargan otra vez cada vez que abro"). Aquí el
/// tope sube a 2500 portadas y 60 días; a ~20 KB por miniatura son unos 50 MB
/// en el peor caso, y "Borrar caché de imágenes" en Configuración la vacía.
class AppImageCache {
  AppImageCache._();

  static const key = 'syncoraCoverCache';

  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 60),
      maxNrOfCacheObjects: 2500,
      fileService: _RetryingFileService(),
    ),
  );
}

/// Descargas de portadas que sobreviven a las conexiones muertas de la red
/// móvil (ronda 5, H-R5-5).
///
/// Síntoma: en el teléfono fallaban portadas **en grupo** (rachas seguidas en
/// una playlist grande, la mitad de las recomendaciones), nunca en el PC con
/// los mismos datos. `HttpClient` reutiliza una conexión ociosa hasta 15 s,
/// pero el NAT de las redes móviles y de muchos routers la corta antes sin
/// avisar: la siguiente tanda de peticiones sale por conexiones que ya no
/// existen y fallan todas juntas ("Connection closed before full header was
/// received"). Dos defensas:
/// - conexiones ociosas de 4 s como mucho, para casi nunca reutilizar una
///   muerta;
/// - un reintento inmediato cuando el fallo es de conexión (nunca ante una
///   respuesta HTTP real como un 404), que ya sale por una conexión nueva.
class _RetryingFileService extends FileService {
  _RetryingFileService()
      : _inner = HttpFileService(
          httpClient: IOClient(
            HttpClient()
              ..idleTimeout = const Duration(seconds: 4)
              ..connectionTimeout = const Duration(seconds: 12),
          ),
        ) {
    concurrentFetches = 8;
  }

  final HttpFileService _inner;

  @override
  Future<FileServiceResponse> get(String url, {Map<String, String>? headers}) async {
    try {
      return await _inner.get(url, headers: headers);
    } on Object catch (e) {
      if (!_isConnectionError(e)) rethrow;
      debugPrint('[Covers] Reintento tras fallo de conexión ($e): $url');
      return _inner.get(url, headers: headers);
    }
  }

  static bool _isConnectionError(Object e) =>
      e is SocketException ||
      e is HttpException ||
      e is http.ClientException ||
      e is TimeoutException ||
      e is HandshakeException;
}
