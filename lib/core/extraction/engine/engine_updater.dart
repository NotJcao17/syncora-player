import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'engine_bundle.dart';
import 'engine_manifest.dart';
import 'engine_trust.dart';

/// Red del OTA: baja el manifiesto firmado y los motores de la release
/// `engine-channel` de GitHub. No decide nada; solo descarga y verifica.
class EngineUpdater {
  EngineUpdater({
    Dio? dio,
    this.manifestUrl = kEngineManifestUrl,
    this.baseUrl = kEngineChannelBaseUrl,
    List<int>? publicKey,
  })  : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
              followRedirects: true,
              maxRedirects: 5,
            )),
        _publicKey = publicKey ?? (isEngineOtaConfigured ? base64Decode(kEnginePublicKeyBase64) : const []);

  final Dio _dio;
  final String manifestUrl;
  final String baseUrl;
  final List<int> _publicKey;

  /// Techo del `.js.gz` y del motor descomprimido. El motor real pesa
  /// ~260 KB comprimido y ~1.7 MB sin comprimir; esto solo evita que un
  /// archivo absurdo (o una bomba de gzip) se coma la memoria.
  static const int maxCompressedBytes = 16 * 1024 * 1024;
  static const int maxEngineBytes = 32 * 1024 * 1024;

  Future<EngineManifest> fetchManifest() async {
    final res = await _dio.get<String>(
      manifestUrl,
      options: Options(
        responseType: ResponseType.plain,
        headers: {'cache-control': 'no-cache'},
      ),
    );
    if (res.statusCode != 200 || res.data == null) {
      throw EngineManifestException('HTTP ${res.statusCode} al pedir el manifiesto');
    }
    return EngineManifest.verifyAndParse(res.data!, publicKey: _publicKey);
  }

  /// Baja, descomprime y verifica un motor. Devuelve los bytes del JS solo si
  /// coinciden con el tamaño y el SHA-256 del manifiesto firmado.
  Future<List<int>> download(EngineRelease release) async {
    final res = await _dio.get<List<int>>(
      '$baseUrl/${release.file}',
      options: Options(responseType: ResponseType.bytes),
    );
    final compressed = res.data;
    if (res.statusCode != 200 || compressed == null) {
      throw HttpException('HTTP ${res.statusCode} al bajar ${release.file}');
    }
    if (compressed.length > maxCompressedBytes) {
      throw const FormatException('Motor comprimido demasiado grande');
    }
    if (release.info.size > maxEngineBytes) {
      throw const FormatException('Motor demasiado grande');
    }
    final bytes = gunzipBounded(compressed, release.info.size);
    if (bytes.length != release.info.size) {
      throw FormatException('Tamaño ${bytes.length} distinto al firmado (${release.info.size})');
    }
    if (engineSha256(bytes) != release.info.sha256) {
      throw const FormatException('El SHA-256 del motor no coincide con el manifiesto firmado');
    }
    return bytes;
  }
}

/// Descomprime sin pasar de [maxBytes]: corta en cuanto el resultado crece
/// más de lo que dice el manifiesto, en vez de descomprimirlo todo primero.
List<int> gunzipBounded(List<int> data, int maxBytes) {
  final sink = _BoundedSink(maxBytes);
  final input = gzip.decoder.startChunkedConversion(sink);
  const chunk = 64 * 1024;
  for (var i = 0; i < data.length; i += chunk) {
    input.add(data.sublist(i, i + chunk > data.length ? data.length : i + chunk));
  }
  input.close();
  return sink.builder.takeBytes();
}

class _BoundedSink implements Sink<List<int>> {
  _BoundedSink(this.maxBytes);
  final int maxBytes;
  final BytesBuilder builder = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    builder.add(data);
    if (builder.length > maxBytes) {
      throw const FormatException('El motor descomprimido es más grande que lo firmado');
    }
  }

  @override
  void close() {}
}
