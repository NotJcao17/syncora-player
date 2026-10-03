// Prueba estatica del motor (sin red): que cargue en QuickJS real y en un
// contexto limpio de Node, y que exponga el contrato que espera Dart.
// Es el gate obligatorio antes de firmar y publicar un motor.
//
//   node test/check.mjs [ruta/al/motor.js]
//
// Sale con codigo 1 si algo falla.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { getQuickJS } from 'quickjs-emscripten';

import { loadEngine } from './harness.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const enginePath = resolve(process.argv[2] ?? resolve(root, '../assets/js/syncora_engine.js'));
const code = readFileSync(enginePath, 'utf8');
const config = JSON.parse(readFileSync(resolve(root, 'engine.config.json'), 'utf8'));

const CONTRACT_EXPR = `JSON.stringify({
  extractVideo: typeof globalThis.extractVideo === 'function',
  searchVideos: typeof globalThis.searchVideos === 'function',
  resetJsEngine: typeof globalThis.resetJsEngine === 'function',
  innertube: typeof globalThis.Innertube === 'function',
  info: globalThis.SYNCORA_ENGINE || null
})`;

function assertContract(label, c) {
  const problems = [];
  if (!c.extractVideo) problems.push('falta extractVideo');
  if (!c.searchVideos) problems.push('falta searchVideos');
  if (!c.resetJsEngine) problems.push('falta resetJsEngine');
  if (c.innertube === false) problems.push('youtubei.js no expuso Innertube');
  if (!c.info) problems.push('falta SYNCORA_ENGINE');
  else {
    if (c.info.api !== config.api) problems.push(`api ${c.info.api} != ${config.api}`);
    if (!Number.isSafeInteger(c.info.build) || c.info.build <= 0) problems.push('build invalido');
    if (!Array.isArray(c.info.clients) || c.info.clients.length === 0) problems.push('sin clientes');
  }
  if (problems.length) {
    console.error(`[${label}] FALLA: ${problems.join(', ')}`);
    return false;
  }
  console.log(`[${label}] OK (build ${c.info.build}, clientes ${c.info.clients.join(', ')})`);
  return true;
}

async function checkQuickJs() {
  const QuickJS = await getQuickJS();
  const runtime = QuickJS.newRuntime();
  runtime.setMemoryLimit(512 * 1024 * 1024);
  const vm = runtime.newContext();
  try {
    const sendMessage = vm.newFunction('sendMessage', () => vm.undefined);
    vm.setProp(vm.global, 'sendMessage', sendMessage);
    sendMessage.dispose();

    const loaded = vm.evalCode(code, 'syncora_engine.js');
    if (loaded.error) {
      const err = vm.dump(loaded.error);
      loaded.error.dispose();
      console.error('[QuickJS] FALLA al evaluar el motor:', err);
      return false;
    }
    loaded.value.dispose();

    const res = vm.evalCode(CONTRACT_EXPR);
    if (res.error) {
      console.error('[QuickJS] FALLA leyendo el contrato:', vm.dump(res.error));
      res.error.dispose();
      return false;
    }
    const contract = JSON.parse(vm.getString(res.value));
    res.value.dispose();
    return assertContract('QuickJS', contract);
  } finally {
    vm.dispose();
    runtime.dispose();
  }
}

function checkNode() {
  try {
    const engine = loadEngine(code);
    const c = engine.contract();
    c.innertube = typeof engine.ctx.Innertube === 'function';
    return assertContract('Node vm', c);
  } catch (e) {
    console.error('[Node vm] FALLA al evaluar el motor:', e);
    return false;
  }
}

const ok = (await checkQuickJs()) & checkNode();
process.exit(ok ? 0 : 1);
