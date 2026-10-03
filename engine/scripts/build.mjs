// Arma el motor completo que ejecuta QuickJS en la app:
//
//   polyfills.js + vendor/youtubei.bundle.js + glue.js + metadatos
//
// y escribe el JS y su ficha (`.json`) con build, api y SHA-256. Es el mismo
// orden y los mismos separadores que usaba `JsBundleLoader` cuando las piezas
// vivian en strings de Dart, asi que el resultado se comporta igual.
//
// Uso:
//   node scripts/build.mjs                       -> assets/js/syncora_engine.{js,json}
//   node scripts/build.mjs --out dist/engine.js  -> otra ruta (CI)
//   node scripts/build.mjs --vendor x.js --youtubei 18.1.0 --out y.js
//   ENGINE_BUILD=202610021530 node scripts/build.mjs
//
// El build es un entero creciente (AAAAMMDDHHmm en UTC por defecto). La app
// nunca instala un motor con build menor o igual al que ya tiene.

import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export function defaultBuildNumber(date = new Date()) {
  const p = (n) => String(n).padStart(2, '0');
  return Number(
    `${date.getUTCFullYear()}${p(date.getUTCMonth() + 1)}${p(date.getUTCDate())}` +
      `${p(date.getUTCHours())}${p(date.getUTCMinutes())}`,
  );
}

export function buildEngine({ build, vendorPath, youtubeiVersion } = {}) {
  const config = JSON.parse(readFileSync(resolve(root, 'engine.config.json'), 'utf8'));
  const youtubei = youtubeiVersion ?? readFileSync(resolve(root, 'vendor/youtubei.version'), 'utf8').trim();
  const polyfills = readFileSync(resolve(root, 'src/polyfills.js'), 'utf8');
  const vendor = readFileSync(vendorPath ?? resolve(root, 'vendor/youtubei.bundle.js'), 'utf8');
  const glue = readFileSync(resolve(root, 'src/glue.js'), 'utf8');

  const info = {
    api: config.api,
    build,
    youtubei,
    clients: config.clients,
  };
  // Contrato con Dart (engine api 1): `extractVideo`, `searchVideos`,
  // `resetJsEngine` y este objeto. El isolate lo lee tras evaluar el motor
  // para saber que cargo bien y que jerarquia de clientes usar.
  const footer = `globalThis.SYNCORA_ENGINE = Object.freeze(${JSON.stringify(info)});\n`;

  const code = `${polyfills}\n\n${vendor}\n\n${glue}\n\n${footer}`;
  const bytes = Buffer.from(code, 'utf8');
  const meta = {
    api: config.api,
    build,
    youtubei,
    size: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex'),
  };
  return { code, bytes, meta };
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--out') args.out = argv[++i];
    else if (argv[i] === '--vendor') args.vendor = argv[++i];
    else if (argv[i] === '--youtubei') args.youtubei = argv[++i];
  }
  return args;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = parseArgs(process.argv.slice(2));
  const build = process.env.ENGINE_BUILD ? Number(process.env.ENGINE_BUILD) : defaultBuildNumber();
  if (!Number.isSafeInteger(build) || build <= 0) {
    throw new Error(`ENGINE_BUILD invalido: ${process.env.ENGINE_BUILD}`);
  }
  const out = resolve(args.out ?? resolve(root, '../assets/js/syncora_engine.js'));
  const { bytes, meta } = buildEngine({
    build,
    vendorPath: args.vendor && resolve(args.vendor),
    youtubeiVersion: args.youtubei,
  });
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, bytes);
  writeFileSync(out.replace(/\.js$/, '.json'), JSON.stringify(meta, null, 2) + '\n');
  console.log(`Motor ${meta.build} (api ${meta.api}, youtubei.js ${meta.youtubei}) -> ${out} [${meta.size} bytes]`);
}
