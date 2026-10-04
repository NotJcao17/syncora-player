import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// Versión del contrato Dart↔JS que entiende esta app (Fase 8).
///
/// El contrato es lo que el isolate de extracción espera del motor:
/// `extractVideo`, `searchVideos`, `resetJsEngine`, el objeto
/// `SYNCORA_ENGINE` y los canales de `sendMessage` (`dartFetch`,
/// `setTimeout`, `consoleLog`, `extractionResult`, `searchResult`). Si algún
/// día un motor necesita algo nuevo del lado de Dart, sube a `api: 2` y las
/// apps con esta constante en 1 simplemente no lo descargan.
const int kSupportedEngineApi = 1;

/// Jerarquía de clientes de Innertube si el motor no declara la suya.
///
/// Es la que estaba hardcodeada en `extraction_isolate.dart` antes de la
/// Fase 8. Desde entonces el motor la publica en `SYNCORA_ENGINE.clients` y
/// se puede cambiar por OTA (deuda anotada en `docs/fases/fase_1.md`).
const List<String> kDefaultEngineClients = ['ANDROID', 'ANDROID_VR', 'WEB'];

enum EngineSource {
  /// El que viene dentro del APK/EXE (`assets/js/syncora_engine.js`).
  embedded,

  /// Uno bajado por OTA y verificado.
  downloaded,
}

/// Ficha de un motor: lo que dice su `.json` (fábrica) o el manifiesto
/// firmado (OTA).
@immutable
class EngineInfo {
  final int build;
  final int api;
  final String sha256;
  final int size;
  final String? youtubei;

  const EngineInfo({
    required this.build,
    required this.api,
    required this.sha256,
    required this.size,
    this.youtubei,
  });

  factory EngineInfo.fromJson(Map<String, dynamic> json) => EngineInfo(
        build: (json['build'] as num).toInt(),
        api: (json['api'] as num).toInt(),
        sha256: (json['sha256'] as String).toLowerCase(),
        size: (json['size'] as num).toInt(),
        youtubei: json['youtubei'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'build': build,
        'api': api,
        'sha256': sha256,
        'size': size,
        if (youtubei != null) 'youtubei': youtubei,
      };
}

/// Un motor listo para cargarse en QuickJS.
@immutable
class EngineBundle {
  final String code;
  final EngineInfo info;
  final EngineSource source;

  const EngineBundle({
    required this.code,
    required this.info,
    required this.source,
  });

  int get build => info.build;
}

/// SHA-256 en hex de los bytes UTF-8 de un motor — lo mismo que calcula
/// `engine/scripts/build.mjs`.
String engineSha256(List<int> bytes) => sha256.convert(bytes).toString();
