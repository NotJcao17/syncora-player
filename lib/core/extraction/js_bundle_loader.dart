import 'dart:convert';

import 'package:flutter/services.dart';

import 'engine/engine_bundle.dart';

/// Carga el motor **de fábrica** que viaja dentro del APK/EXE.
///
/// Hasta la Fase 8 este archivo guardaba los polyfills y el pegamento
/// (`extractVideo`, `searchVideos`…) como strings de Dart y los concatenaba
/// con `youtubei.bundle.js`. Eso impedía actualizarlos por OTA (hallazgo
/// H-8-2), así que ahora viven en `engine/src/` y
/// `engine/scripts/build.mjs` genera un único `assets/js/syncora_engine.js`
/// (+ su ficha `.json`) con el mismo orden y separadores de antes. Ese es el
/// mismo formato que se publica por OTA.
class JsBundleLoader {
  static const String engineAsset = 'assets/js/syncora_engine.js';
  static const String engineInfoAsset = 'assets/js/syncora_engine.json';

  static Future<EngineBundle> loadEmbedded() async {
    final code = await rootBundle.loadString(engineAsset);
    final info = EngineInfo.fromJson(
      jsonDecode(await rootBundle.loadString(engineInfoAsset)) as Map<String, dynamic>,
    );
    return EngineBundle(code: code, info: info, source: EngineSource.embedded);
  }
}
