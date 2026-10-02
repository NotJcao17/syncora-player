// `deno test cloudflare/image-worker/src/keys_test.ts`
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

import { imageKeyFromPath } from "./keys.ts";

const USER = "8a1f7c3e-2b4d-4e6f-9a0b-1c2d3e4f5a6b";
const PLAYLIST = "11111111-2222-4333-8444-555555555555";
const NAME = "0123456789abcdef0123456789abcdef";

Deno.test("acepta portadas y fotos de perfil con el formato de la Edge Function", () => {
  assertEquals(imageKeyFromPath(`/u/${USER}/a/${NAME}.jpg`), `u/${USER}/a/${NAME}.jpg`);
  assertEquals(imageKeyFromPath(`/u/${USER}/p/${PLAYLIST}/${NAME}.jpg`), `u/${USER}/p/${PLAYLIST}/${NAME}.jpg`);
});

Deno.test("rechaza cualquier otra ruta sin llegar al bucket", () => {
  assertEquals(imageKeyFromPath("/"), null);
  assertEquals(imageKeyFromPath("/favicon.ico"), null);
  assertEquals(imageKeyFromPath(`/u/${USER}/`), null);
  assertEquals(imageKeyFromPath(`/u/${USER}/a/${NAME}.png`), null);
  assertEquals(imageKeyFromPath(`/u/${USER}/a/${NAME}x.jpg`), null);
  assertEquals(imageKeyFromPath(`/u/${USER}/p/../${NAME}.jpg`), null);
  assertEquals(imageKeyFromPath(`/u/${USER.toUpperCase()}/a/${NAME}.jpg`), null);
});
