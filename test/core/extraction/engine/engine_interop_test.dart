import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/extraction/engine/engine_bundle.dart';
import 'package:syncora_player/core/extraction/engine/engine_manifest.dart';
import 'package:syncora_player/core/extraction/engine/engine_updater.dart';

/// El manifiesto y el `.js.gz` de `test/fixtures/engine/` los generó
/// `engine/scripts/sign.mjs` (Node) con una llave de prueba. Este test es la
/// garantía de que lo que firma el pipeline de CI lo acepta la app: si alguno
/// de los dos lados cambia el formato, falla aquí y no en producción.
void main() {
  const dir = 'test/fixtures/engine';

  test('la app verifica un manifiesto firmado por sign.mjs y su motor comprimido', () async {
    final publicKey = base64Decode(File('$dir/test_public_key.txt').readAsStringSync().trim());
    final manifest = await EngineManifest.verifyAndParse(
      File('$dir/engine-manifest.json').readAsStringSync(),
      publicKey: publicKey,
    );

    final release = manifest.latestFor(kSupportedEngineApi)!;
    expect(release.build, 202610020101);
    expect(release.file, 'engine-202610020101.js.gz');
    expect(release.rollout, EngineRollout.onFailure);
    expect(manifest.revoked, {202609010000});

    final js = gunzipBounded(File('$dir/${release.file}').readAsBytesSync(), release.info.size);
    expect(js.length, release.info.size);
    expect(engineSha256(js), release.info.sha256);
  });

  test('gunzipBounded corta si el contenido crece más de lo firmado', () {
    final big = gzip.encode(List<int>.filled(100000, 65));
    expect(() => gunzipBounded(big, 1000), throwsFormatException);
  });
}
