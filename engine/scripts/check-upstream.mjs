// Decide si hay una version nueva de youtubei.js lista para construir.
//
//   node scripts/check-upstream.mjs
//
// Escribe en $GITHUB_OUTPUT (o imprime, en local):
//   action=update|none
//   version=<x.y.z>
//   reason=<texto>
//
// Reglas:
// - Solo la etiqueta `latest` de npm (nunca betas).
// - Cuarentena de 24 h desde que se publico: si un paquete de npm sale
//   comprometido, casi siempre se retira en horas.
// - Las versiones que ya fallaron las pruebas (vendor/rejected-versions.txt)
//   no se reintentan: asi un fallo avisa por correo una sola vez.

import { execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const QUARANTINE_HOURS = Number(process.env.ENGINE_QUARANTINE_HOURS ?? 24);
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function output(values) {
  const lines = Object.entries(values).map(([k, v]) => `${k}=${v}`);
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, lines.join('\n') + '\n');
  console.log(lines.join('\n'));
}

const info = JSON.parse(
  execFileSync('npm', ['view', 'youtubei.js', 'version', 'time', '--json'], {
    encoding: 'utf8',
    shell: process.platform === 'win32',
  }),
);
const latest = info.version;
const publishedAt = new Date(info.time[latest]);
const current = readFileSync(resolve(root, 'vendor/youtubei.version'), 'utf8').trim();
const rejectedPath = resolve(root, 'vendor/rejected-versions.txt');
const rejected = existsSync(rejectedPath)
  ? readFileSync(rejectedPath, 'utf8').split('\n').map((l) => l.trim()).filter(Boolean)
  : [];

if (latest === current) {
  output({ action: 'none', version: latest, reason: 'ya-al-dia' });
} else if (rejected.includes(latest)) {
  output({ action: 'none', version: latest, reason: 'rechazada-antes' });
} else {
  const ageHours = (Date.now() - publishedAt.getTime()) / 3_600_000;
  if (ageHours < QUARANTINE_HOURS) {
    output({ action: 'none', version: latest, reason: `cuarentena-${Math.floor(ageHours)}h` });
  } else {
    output({ action: 'update', version: latest, reason: `${current}->${latest}` });
  }
}
