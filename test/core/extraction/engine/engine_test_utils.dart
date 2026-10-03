import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:syncora_player/core/extraction/engine/engine_bundle.dart';

/// Motor de mentira: el contenido da igual, lo que importa es que su ficha
/// (tamaño + SHA-256) coincida con los bytes.
({String code, List<int> bytes, EngineInfo info}) fakeEngine(int build, {int api = kSupportedEngineApi}) {
  final code = '/* motor $build */ globalThis.SYNCORA_ENGINE = {api: $api, build: $build};';
  final bytes = utf8.encode(code);
  return (
    code: code,
    bytes: bytes,
    info: EngineInfo(build: build, api: api, sha256: engineSha256(bytes), size: bytes.length, youtubei: '18.1.0'),
  );
}

EngineBundle embeddedBundle(int build) {
  final e = fakeEngine(build);
  return EngineBundle(code: e.code, info: e.info, source: EngineSource.embedded);
}

/// Firma un payload igual que `engine/scripts/sign.mjs`.
class TestSigner {
  TestSigner._(this._keyPair, this.publicKey);

  final SimpleKeyPair _keyPair;
  final List<int> publicKey;

  static Future<TestSigner> create() async {
    final kp = await Ed25519().newKeyPair();
    final pub = await kp.extractPublicKey();
    return TestSigner._(kp, pub.bytes);
  }

  Future<String> sign(Map<String, dynamic> payload) async {
    final payloadBytes = utf8.encode(jsonEncode(payload));
    final sig = await Ed25519().sign(payloadBytes, keyPair: _keyPair);
    return jsonEncode({
      'payload': base64Encode(payloadBytes),
      'signature': base64Encode(sig.bytes),
    });
  }
}

Map<String, dynamic> manifestPayload(
  List<EngineInfo> engines, {
  String rollout = 'on_failure',
  List<int> revoked = const [],
}) =>
    {
      'schema': 1,
      'engines': [
        for (final e in engines)
          {
            ...e.toJson(),
            'file': 'engine-${e.build}.js.gz',
            'rollout': rollout,
          },
      ],
      'revoked': revoked,
    };
