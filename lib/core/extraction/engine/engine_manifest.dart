import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'engine_bundle.dart';

/// Cuándo deben activar las apps un motor publicado.
enum EngineRollout {
  /// Por defecto: queda guardado y solo se usa si el motor activo falla.
  onFailure,

  /// "Aplicar a todos" del workflow manual: se activa en el siguiente
  /// arranque aunque el motor activo funcione.
  nextLaunch,
}

class EngineManifestException implements Exception {
  final String message;
  const EngineManifestException(this.message);
  @override
  String toString() => 'EngineManifestException: $message';
}

/// Un motor anunciado por el manifiesto.
@immutable
class EngineRelease {
  final EngineInfo info;

  /// Nombre del archivo `.js.gz` dentro de la release `engine-channel`.
  /// Validado contra [_fileNamePattern]: nunca puede apuntar fuera.
  final String file;
  final EngineRollout rollout;

  const EngineRelease({
    required this.info,
    required this.file,
    required this.rollout,
  });

  int get build => info.build;
  int get api => info.api;
}

/// Manifiesto del canal de motores, **ya verificado**.
///
/// Formato publicado (`engine-manifest.json`), generado por
/// `engine/scripts/sign.mjs`:
///
/// ```json
/// {"payload": "<base64 del JSON>", "signature": "<base64 Ed25519 sobre esos bytes>"}
/// ```
///
/// La firma cubre los bytes exactos del payload, así que no hay ninguna
/// canonicalización de JSON que pueda divergir entre Node y Dart. Como el
/// payload incluye el SHA-256 de cada motor, una sola firma protege todo.
@immutable
class EngineManifest {
  final List<EngineRelease> engines;
  final Set<int> revoked;

  const EngineManifest({required this.engines, required this.revoked});

  /// El motor más nuevo compatible con [api], o `null` si no hay ninguno.
  EngineRelease? latestFor(int api) {
    EngineRelease? best;
    for (final e in engines) {
      if (e.api != api) continue;
      if (best == null || e.build > best.build) best = e;
    }
    return best;
  }

  static final RegExp _fileNamePattern = RegExp(r'^engine-\d+\.js\.gz$');
  static const int _maxBodyBytes = 64 * 1024;

  /// Verifica la firma con [publicKey] (32 bytes) y parsea. Lanza
  /// [EngineManifestException] ante cualquier cosa rara: el llamador debe
  /// tratarlo como "no hay actualización", nunca como un error fatal.
  static Future<EngineManifest> verifyAndParse(
    String body, {
    required List<int> publicKey,
  }) async {
    if (body.length > _maxBodyBytes) {
      throw const EngineManifestException('Manifiesto demasiado grande');
    }
    if (publicKey.length != 32) {
      throw const EngineManifestException('Llave pública inválida');
    }

    final List<int> payloadBytes;
    final List<int> signatureBytes;
    try {
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      payloadBytes = base64Decode(envelope['payload'] as String);
      signatureBytes = base64Decode(envelope['signature'] as String);
    } catch (e) {
      throw EngineManifestException('Sobre mal formado: $e');
    }
    if (signatureBytes.length != 64) {
      throw const EngineManifestException('Firma de tamaño inválido');
    }

    final valid = await Ed25519().verify(
      payloadBytes,
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
    if (!valid) {
      throw const EngineManifestException('Firma inválida');
    }

    // A partir de aquí el contenido es de confianza, pero se valida igual:
    // un manifiesto firmado con un bug no debe tumbar la app.
    try {
      final payload = jsonDecode(utf8.decode(payloadBytes)) as Map<String, dynamic>;
      final engines = <EngineRelease>[];
      for (final raw in (payload['engines'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(raw as Map);
        final file = m['file'] as String;
        if (!_fileNamePattern.hasMatch(file)) {
          throw EngineManifestException('Nombre de archivo no permitido: $file');
        }
        final info = EngineInfo.fromJson(m);
        if (info.build <= 0 || info.size <= 0 || info.sha256.length != 64) {
          throw EngineManifestException('Motor ${info.build} con datos inválidos');
        }
        engines.add(EngineRelease(
          info: info,
          file: file,
          rollout: m['rollout'] == 'next_launch' ? EngineRollout.nextLaunch : EngineRollout.onFailure,
        ));
      }
      final revoked = <int>{
        for (final r in (payload['revoked'] as List? ?? const [])) (r as num).toInt(),
      };
      return EngineManifest(engines: List.unmodifiable(engines), revoked: Set.unmodifiable(revoked));
    } on EngineManifestException {
      rethrow;
    } catch (e) {
      throw EngineManifestException('Contenido inválido: $e');
    }
  }
}
