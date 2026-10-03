// Genera el par de llaves Ed25519 que firma el manifiesto del OTA.
//
//   node scripts/keygen.mjs [--force]
//
// - La llave PRIVADA se escribe en engine/signing_key.pem (ignorado por Git).
//   Hay que subirla como secreto ENGINE_SIGNING_KEY de GitHub Actions y
//   guardar una copia en un lugar seguro (gestor de contrasenas). No se
//   imprime nunca por pantalla.
// - La llave PUBLICA se escribe directamente en
//   lib/core/extraction/engine/engine_trust.dart (va dentro de la app).
//
// Regenerar las llaves invalida el OTA para todas las apps ya instaladas
// (seguiran con su motor actual hasta que instalen una version nueva de la
// app con la llave nueva). Solo se hace si la privada se filtro.

import { generateKeyPairSync } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const privatePath = resolve(root, 'signing_key.pem');
const trustPath = resolve(root, '../lib/core/extraction/engine/engine_trust.dart');

if (existsSync(privatePath) && !process.argv.includes('--force')) {
  console.error(`Ya existe ${privatePath}. Usa --force solo si de verdad quieres reemplazar la llave.`);
  process.exit(1);
}

const { publicKey, privateKey } = generateKeyPairSync('ed25519');
const rawPublic = Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url');
const publicB64 = rawPublic.toString('base64');

writeFileSync(privatePath, privateKey.export({ format: 'pem', type: 'pkcs8' }), { mode: 0o600 });

const trust = readFileSync(trustPath, 'utf8');
const pattern = /const String kEnginePublicKeyBase64 = '[^']*';/;
if (!pattern.test(trust)) throw new Error('No encontre kEnginePublicKeyBase64 en engine_trust.dart');
writeFileSync(trustPath, trust.replace(pattern, `const String kEnginePublicKeyBase64 = '${publicB64}';`));

console.log('Llave privada  -> engine/signing_key.pem (NO se sube a Git)');
console.log(`Llave publica  -> engine_trust.dart (${publicB64})`);
console.log('\nSiguientes pasos:');
console.log('  1. gh secret set ENGINE_SIGNING_KEY < engine/signing_key.pem');
console.log('  2. Guarda una copia de engine/signing_key.pem en tu gestor de contrasenas.');
