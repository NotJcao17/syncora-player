// Prueba en vivo del motor contra YouTube: busca una cancion conocida,
// extrae su URL con la jerarquia de clientes del propio motor y comprueba
// que el audio responde.
//
//   node test/live.mjs [ruta/al/motor.js] [--verbose]
//
// Codigos de salida:
//   0  funciona
//   1  roto (el motor falla con YouTube contestando normalmente)
//   2  inconcluso: YouTube bloqueo la IP (pide iniciar sesion / "no eres un
//      bot"). Pasa casi siempre desde servidores de GitHub Actions, que son
//      IPs de datacenter (Pitfall #1), y no dice nada del motor.
//
// No es un gate de publicacion por eso mismo; lo usa el workflow canario para
// avisar por correo cuando el motor publicado deja de funcionar.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { loadEngine } from './harness.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const verbose = args.includes('--verbose');
const enginePath = resolve(args.find((a) => !a.startsWith('--')) ?? resolve(root, '../assets/js/syncora_engine.js'));

const QUERIES = ['Coldplay Yellow', 'Daft Punk Get Lucky', 'Bad Bunny Titi Me Pregunto'];
const BLOCK_MARKERS = ['sign in to confirm', 'login_required', 'not a bot', 'unusual traffic', 'captcha'];

const isBlocked = (text) => BLOCK_MARKERS.some((m) => String(text).toLowerCase().includes(m));

const engine = loadEngine(readFileSync(enginePath, 'utf8'), { verbose });
const clients = engine.info?.clients ?? ['ANDROID', 'ANDROID_VR', 'WEB'];
console.log(`Motor build ${engine.info?.build} (youtubei.js ${engine.info?.youtubei}), clientes: ${clients.join(', ')}`);

let successes = 0;
let blocked = 0;
const errors = [];

for (const query of QUERIES) {
  const search = await engine.search(query, 'WEB', 'music');
  const candidate = search.results?.[0];
  if (!candidate) {
    const reason = search.error ?? 'sin resultados';
    if (isBlocked(reason)) blocked++;
    else errors.push(`busqueda "${query}": ${reason}`);
    console.log(`  "${query}": busqueda sin candidatos (${String(reason).slice(0, 120)})`);
    continue;
  }

  let extracted = null;
  const clientErrors = [];
  for (const client of clients) {
    const res = await engine.extract(candidate.videoId, client);
    if (res.url) {
      extracted = { client, ...res };
      break;
    }
    clientErrors.push(`${client}: ${String(res.error).split('\n')[0].slice(0, 160)}`);
  }

  if (!extracted) {
    const joined = clientErrors.join(' | ');
    if (isBlocked(joined)) blocked++;
    else errors.push(`extraccion ${candidate.videoId}: ${joined}`);
    console.log(`  "${query}" -> ${candidate.videoId}: sin URL (${joined.slice(0, 200)})`);
    continue;
  }

  const audio = await fetch(extracted.url, {
    headers: { ...extracted.headers, range: 'bytes=0-4095' },
    signal: AbortSignal.timeout(15000),
  }).catch((e) => ({ status: 0, statusText: String(e) }));
  if (audio.status === 200 || audio.status === 206) {
    successes++;
    console.log(`  "${query}" -> ${candidate.videoId} via ${extracted.client}: audio ${audio.status} OK`);
  } else {
    errors.push(`audio ${candidate.videoId} via ${extracted.client}: HTTP ${audio.status}`);
    console.log(`  "${query}" -> ${candidate.videoId} via ${extracted.client}: audio HTTP ${audio.status}`);
  }
}

if (successes > 0) {
  console.log(`RESULTADO: funciona (${successes}/${QUERIES.length})`);
  process.exit(0);
}
if (blocked > 0 && errors.length === 0) {
  console.log('RESULTADO: inconcluso (YouTube bloqueo esta IP)');
  process.exit(2);
}
console.error(`RESULTADO: roto\n  - ${errors.join('\n  - ')}`);
process.exit(1);
