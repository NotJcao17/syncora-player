// Ancla de confianza del OTA del motor (Fase 8).
//
// La llave pública la escribe `engine/scripts/keygen.mjs` (no editarla a mano):
// la privada correspondiente solo existe en el secreto `ENGINE_SIGNING_KEY`
// de GitHub Actions. Mientras esté vacía, el OTA queda desactivado y la app
// usa siempre el motor de fábrica.
//
// Cambiar esta llave invalida todos los motores ya publicados para las apps
// que la traigan: solo se hace si la privada se filtró, y requiere publicar
// la app de nuevo.

/// Llave pública Ed25519 (32 bytes, base64) que firma el manifiesto.
const String kEnginePublicKeyBase64 = 'KKK5O/xvXeCo4dRcV1KdSzmM5aethTxRcfKISs+pO2k=';

/// Release fija de GitHub donde el workflow `publish-engine.yml` publica el
/// manifiesto firmado y los motores (`engine-<build>.js.gz`). Es una
/// *prerelease*, así que nunca se confunde con una release de la app.
const String kEngineChannelBaseUrl =
    'https://github.com/NotJcao17/syncora-player/releases/download/engine-channel';

const String kEngineManifestUrl = '$kEngineChannelBaseUrl/engine-manifest.json';

bool get isEngineOtaConfigured => kEnginePublicKeyBase64.isNotEmpty;
