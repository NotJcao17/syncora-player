# Motor de extracción y su OTA

El motor es el JS que corre en QuickJS dentro del isolate de extracción:

```
src/polyfills.js  +  vendor/youtubei.bundle.js  +  src/glue.js  +  SYNCORA_ENGINE
```

- `src/polyfills.js`: Web APIs que QuickJS no trae (`fetch` → `dartFetch`, `URL`, `TextEncoder`…).
- `vendor/youtubei.bundle.js`: youtubei.js compilado como IIFE global `YouTubeJS` (ES2019). Su versión está en `vendor/youtubei.version`.
- `src/glue.js`: `extractVideo`, `searchVideos`, elección de formato, User-Agent por cliente.
- `engine.config.json`: versión del contrato con Dart (`api`) y jerarquía de clientes de Innertube.

Diseño completo del OTA y sus protecciones: `docs/fases/fase_8.md`.

## Comandos

```bash
npm ci                        # una vez
npm run build                 # regenera assets/js/syncora_engine.{js,json} (el motor de fábrica de la app)
npm run check                 # prueba obligatoria: QuickJS real + contrato
npm run live                  # prueba en vivo contra YouTube (desde tu PC, IP residencial)
npm run update-lib -- 18.1.0  # recompila youtubei.js a esa versión dentro de vendor/
```

Tras cambiar `src/`, `vendor/` o `engine.config.json`: `npm run build && npm run check && npm run live`,
y commitear también `assets/js/syncora_engine.*` si se quiere que el motor de fábrica de la próxima
compilación de la app lo incluya. Al hacer push a `master`, el workflow publica el motor por OTA solo.

## Publicación (GitHub Actions)

- `publish-engine.yml`: cada 6 h revisa npm; si hay youtubei.js nuevo con más de 24 h publicado,
  lo compila, lo prueba, lo firma y lo sube a la release `engine-channel`. También corre en cada
  push que toque el motor, y a mano (con "aplicar a todos" y revocaciones).
- `engine-canary.yml`: una vez al día prueba el motor publicado contra YouTube y falla (te llega
  un correo) si deja de extraer. Desde GitHub suele quedar "inconcluso" porque YouTube bloquea
  IPs de datacenter.

## Llaves

`npm run keygen` genera el par Ed25519: la privada en `engine/signing_key.pem` (ignorada por Git),
la pública directamente en `lib/core/extraction/engine/engine_trust.dart`. La privada va como
secreto `ENGINE_SIGNING_KEY` de GitHub (`gh secret set ENGINE_SIGNING_KEY < engine/signing_key.pem`)
y una copia en un lugar seguro. Si se pierde, se genera otra y hay que publicar la app de nuevo.
