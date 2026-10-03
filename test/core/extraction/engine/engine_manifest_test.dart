import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/extraction/engine/engine_manifest.dart';

import 'engine_test_utils.dart';

void main() {
  late TestSigner signer;

  setUpAll(() async {
    signer = await TestSigner.create();
  });

  test('acepta un manifiesto bien firmado y elige el más nuevo de su api', () async {
    final body = await signer.sign(manifestPayload(
      [fakeEngine(202610010000).info, fakeEngine(202610020000).info, fakeEngine(202610030000, api: 2).info],
      revoked: [202609010000],
    ));
    final manifest = await EngineManifest.verifyAndParse(body, publicKey: signer.publicKey);

    expect(manifest.latestFor(1)!.build, 202610020000);
    expect(manifest.latestFor(2)!.build, 202610030000);
    expect(manifest.latestFor(3), isNull);
    expect(manifest.revoked, {202609010000});
    expect(manifest.latestFor(1)!.rollout, EngineRollout.onFailure);
  });

  test('lee el rollout "aplicar a todos"', () async {
    final body = await signer.sign(manifestPayload([fakeEngine(202610020000).info], rollout: 'next_launch'));
    final manifest = await EngineManifest.verifyAndParse(body, publicKey: signer.publicKey);
    expect(manifest.latestFor(1)!.rollout, EngineRollout.nextLaunch);
  });

  test('rechaza un payload alterado después de firmar', () async {
    final body = await signer.sign(manifestPayload([fakeEngine(202610020000).info]));
    final envelope = jsonDecode(body) as Map<String, dynamic>;
    final payload = jsonDecode(utf8.decode(base64Decode(envelope['payload'] as String))) as Map<String, dynamic>;
    // Un atacante cambia el hash por el de su propio motor.
    (payload['engines'] as List).first['sha256'] = 'f' * 64;
    envelope['payload'] = base64Encode(utf8.encode(jsonEncode(payload)));

    expect(
      () => EngineManifest.verifyAndParse(jsonEncode(envelope), publicKey: signer.publicKey),
      throwsA(isA<EngineManifestException>()),
    );
  });

  test('rechaza una firma hecha con otra llave', () async {
    final other = await TestSigner.create();
    final body = await other.sign(manifestPayload([fakeEngine(202610020000).info]));
    expect(
      () => EngineManifest.verifyAndParse(body, publicKey: signer.publicKey),
      throwsA(isA<EngineManifestException>()),
    );
  });

  test('rechaza nombres de archivo que podrían salirse de la release', () async {
    final payload = manifestPayload([fakeEngine(202610020000).info]);
    (payload['engines'] as List).first['file'] = '../../evil.js.gz';
    final body = await signer.sign(payload);
    expect(
      () => EngineManifest.verifyAndParse(body, publicKey: signer.publicKey),
      throwsA(isA<EngineManifestException>()),
    );
  });

  test('rechaza basura sin lanzar otra cosa que EngineManifestException', () async {
    for (final body in ['', 'no es json', '{"payload": 1}', '{"payload":"AA==","signature":"AA=="}']) {
      expect(
        () => EngineManifest.verifyAndParse(body, publicKey: signer.publicKey),
        throwsA(isA<EngineManifestException>()),
        reason: body,
      );
    }
  });
}
