// Recompila youtubei.js desde npm al formato que espera el motor: un IIFE
// global `YouTubeJS` construido desde su entrada web, en ES2019 (el mismo
// target con el que se hizo el vendor original; QuickJS de flutter_js es de
// 2021 y no conviene arriesgar sintaxis mas nueva).
//
//   node scripts/update-lib.mjs <version>             -> reemplaza vendor/
//   node scripts/update-lib.mjs <version> --out x.js  -> solo escribe x.js
//
// Lo usa el workflow automatico cuando sale una version nueva, y sirve igual
// a mano. Nunca se actualiza sin pasar despues por `npm run check`.

import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export async function compileYoutubei(version, outFile) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error(`Version invalida: ${version}`);
  const work = mkdtempSync(join(tmpdir(), 'syncora-ytjs-'));
  try {
    writeFileSync(join(work, 'package.json'), '{"private":true}');
    execFileSync('npm', ['install', `youtubei.js@${version}`, '--no-audit', '--no-fund', '--ignore-scripts'], {
      cwd: work,
      stdio: 'inherit',
      shell: process.platform === 'win32',
    });
    await build({
      entryPoints: [join(work, 'node_modules/youtubei.js/dist/src/platform/web.js')],
      bundle: true,
      format: 'iife',
      globalName: 'YouTubeJS',
      platform: 'browser',
      target: 'es2019',
      keepNames: true,
      legalComments: 'inline',
      outfile: outFile,
      logLevel: 'warning',
    });
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [version, ...rest] = process.argv.slice(2);
  const outIdx = rest.indexOf('--out');
  const out = outIdx >= 0 ? resolve(rest[outIdx + 1]) : resolve(root, 'vendor/youtubei.bundle.js');
  await compileYoutubei(version, out);
  if (outIdx < 0) writeFileSync(resolve(root, 'vendor/youtubei.version'), `${version}\n`);
  console.log(`youtubei.js ${version} -> ${out}`);
}
