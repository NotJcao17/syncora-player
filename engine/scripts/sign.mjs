// Comprime el motor y arma + firma el manifiesto del canal OTA.
//
//   ENGINE_SIGNING_KEY="$(cat engine/signing_key.pem)" node scripts/sign.mjs \
//     --engine dist/engine.js --out dist \
//     [--previous prev/engine-manifest.json] [--rollout on_failure|next_launch] \
//     [--revoke 202610020000,202610030000]
//
// Salidas en --out:
//   engine-<build>.js.gz   el motor comprimido (inmutable, un archivo por build)
//   engine-manifest.json   {"payload": base64(JSON), "signature": base64(Ed25519)}
//
// La firma cubre los bytes exactos del payload: la app (engine_manifest.dart)
// los verifica tal cual, sin re-serializar JSON. El payload lleva el SHA-256 y
// el tamano del motor sin comprimir, asi que una firma protege todo.
//
// Del manifiesto anterior se conserva el motor mas nuevo de cada api distinta
// a la del motor nuevo (para que las apps viejas sigan teniendo el suyo) y la
// lista de revocados. Antes de reutilizarlo se verifica su firma.

import { createHash, createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

function trustedPublicKey() {
  const trust = readFileSync(resolve(root, '../lib/core/extraction/engine/engine_trust.dart'), 'utf8');
  const b64 = trust.match(/kEnginePublicKeyBase64 = '([^']*)'/)?.[1];
  if (!b64) return null;
  return createPublicKey({
    key: { kty: 'OKP', crv: 'Ed25519', x: Buffer.from(b64, 'base64').toString('base64url') },
    format: 'jwk',
  });
}

function readPreviousManifest(path) {
  if (!path || !existsSync(path)) return { engines: [], revoked: [] };
  const envelope = JSON.parse(readFileSync(path, 'utf8'));
  const payload = Buffer.from(envelope.payload, 'base64');
  const pub = trustedPublicKey();
  if (!pub || !verify(null, payload, pub, Buffer.from(envelope.signature, 'base64'))) {
    throw new Error('El manifiesto anterior no tiene una firma valida: no se reutiliza nada de el.');
  }
  return JSON.parse(payload.toString('utf8'));
}

const enginePath = resolve(arg('engine', 'dist/engine.js'));
const outDir = resolve(arg('out', 'dist'));
const rollout = arg('rollout', 'on_failure');
if (!['on_failure', 'next_launch'].includes(rollout)) throw new Error(`rollout invalido: ${rollout}`);
const extraRevoked = (arg('revoke', '') || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)
  .map(Number);
if (extraRevoked.some((n) => !Number.isSafeInteger(n))) throw new Error('--revoke debe ser una lista de builds');

const pem = process.env.ENGINE_SIGNING_KEY;
if (!pem) throw new Error('Falta ENGINE_SIGNING_KEY (llave privada PEM).');
const privateKey = createPrivateKey(pem);

const meta = JSON.parse(readFileSync(enginePath.replace(/\.js$/, '.json'), 'utf8'));
const js = readFileSync(enginePath);
const sha256 = createHash('sha256').update(js).digest('hex');
if (sha256 !== meta.sha256 || js.length !== meta.size) {
  throw new Error('El motor no coincide con su ficha .json: no se firma.');
}

const previous = readPreviousManifest(arg('previous'));
const file = `engine-${meta.build}.js.gz`;
const entry = {
  api: meta.api,
  build: meta.build,
  file,
  sha256,
  size: js.length,
  youtubei: meta.youtubei,
  rollout,
  publishedAt: new Date().toISOString(),
};

const latestByApi = new Map();
for (const e of previous.engines ?? []) {
  if (e.api === meta.api) continue;
  const cur = latestByApi.get(e.api);
  if (!cur || e.build > cur.build) latestByApi.set(e.api, e);
}
for (const e of previous.engines ?? []) {
  if (e.api === meta.api && e.build >= meta.build) {
    throw new Error(`Ya hay publicado un motor api ${e.api} con build ${e.build} >= ${meta.build}.`);
  }
}

const revoked = [...new Set([...(previous.revoked ?? []), ...extraRevoked])].sort((a, b) => a - b);
if (revoked.includes(meta.build)) throw new Error('El motor nuevo esta en la lista de revocados.');

const payload = {
  schema: 1,
  generatedAt: new Date().toISOString(),
  engines: [...latestByApi.values(), entry].sort((a, b) => a.api - b.api),
  revoked,
};
const payloadBytes = Buffer.from(JSON.stringify(payload), 'utf8');
const signature = sign(null, payloadBytes, privateKey);

mkdirSync(outDir, { recursive: true });
writeFileSync(resolve(outDir, file), gzipSync(js, { level: 9 }));
writeFileSync(
  resolve(outDir, 'engine-manifest.json'),
  JSON.stringify({ payload: payloadBytes.toString('base64'), signature: signature.toString('base64') }),
);
console.log(`Firmado motor ${meta.build} (api ${meta.api}, youtubei.js ${meta.youtubei}, ${rollout}) -> ${outDir}`);
if (revoked.length) console.log(`Revocados: ${revoked.join(', ')}`);
