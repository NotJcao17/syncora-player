// Ejecuta el motor fuera de la app para probarlo, imitando el puente que le
// da el isolate de Dart (`extraction_isolate.dart`): los canales `consoleLog`,
// `setTimeout`, `dartFetch`, `extractionResult` y `searchResult` de
// `sendMessage`. El contexto de `vm` arranca sin TextEncoder, URL, fetch ni
// setTimeout, igual que QuickJS, asi que los polyfills del motor se ejercitan
// de verdad.

import vm from 'node:vm';

export function loadEngine(code, { verbose = false } = {}) {
  const waiting = new Map();
  const cookies = new Map();
  const ctx = vm.createContext({});
  let seq = 0;

  const log = (msg) => {
    if (verbose) console.log(msg);
  };

  async function dartFetch({ id, url, method, headers, body }) {
    try {
      const reqHeaders = {};
      for (const [k, v] of Object.entries(headers ?? {})) reqHeaders[k.toLowerCase()] = String(v);
      if (cookies.size > 0) {
        reqHeaders.cookie = [...cookies].map(([k, v]) => `${k}=${v}`).join('; ');
      }
      const res = await fetch(url, {
        method: (method ?? 'GET').toUpperCase(),
        headers: reqHeaders,
        body: body ?? undefined,
        redirect: 'follow',
        signal: AbortSignal.timeout(15000),
      });
      for (const c of res.headers.getSetCookie?.() ?? []) {
        const [pair] = c.split(';');
        const eq = pair.indexOf('=');
        if (eq > 0) cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
      }
      const resHeaders = {};
      res.headers.forEach((v, k) => {
        resHeaders[k.toLowerCase()] = v;
      });
      const text = await res.text();
      log(`[dartFetch] ${res.status} ${url.slice(0, 100)}`);
      ctx.__dartFetchResponse(id, res.status, res.statusText || 'OK', resHeaders, text, null);
    } catch (e) {
      ctx.__dartFetchResponse(id, 500, 'Error', {}, '', String(e));
    }
  }

  ctx.sendMessage = (channel, payload) => {
    let data;
    try {
      data = typeof payload === 'string' ? JSON.parse(payload) : payload;
    } catch {
      data = payload;
    }
    switch (channel) {
      case 'consoleLog':
        log(`[JS:${data?.type ?? 'log'}] ${data?.message ?? data}`);
        break;
      case 'setTimeout':
        setTimeout(() => ctx.__fireTimeout(data.id), data.delay ?? 0);
        break;
      case 'dartFetch':
        dartFetch(data);
        break;
      case 'extractionResult':
      case 'searchResult': {
        const resolve = waiting.get(data?.requestId);
        if (resolve) {
          waiting.delete(data.requestId);
          resolve(data);
        }
        break;
      }
      default:
        log(`[harness] canal desconocido: ${channel}`);
    }
  };

  vm.runInContext(code, ctx, { filename: 'syncora_engine.js' });

  function call(fnName, args, timeoutMs) {
    const requestId = `h_${++seq}`;
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        waiting.delete(requestId);
        resolve({ requestId, error: `Timeout (${timeoutMs} ms) esperando ${fnName}` });
      }, timeoutMs);
      waiting.set(requestId, (data) => {
        clearTimeout(timer);
        resolve(data);
      });
      ctx[fnName](...args(requestId));
    });
  }

  return {
    ctx,
    info: ctx.SYNCORA_ENGINE,
    contract() {
      return {
        extractVideo: typeof ctx.extractVideo === 'function',
        searchVideos: typeof ctx.searchVideos === 'function',
        resetJsEngine: typeof ctx.resetJsEngine === 'function',
        info: ctx.SYNCORA_ENGINE ? JSON.parse(JSON.stringify(ctx.SYNCORA_ENGINE)) : null,
      };
    },
    search: (query, client = 'WEB', mode = 'video') =>
      call('searchVideos', (id) => [query, client, id, mode], 20000),
    extract: (videoId, client, quality = 'high') =>
      call('extractVideo', (id) => [videoId, client, id, quality], 25000),
  };
}
