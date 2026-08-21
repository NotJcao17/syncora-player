// Fase 7.E.9 -- tests de los helpers puros que usa index.ts (extraídos a su
// propio módulo justamente para poder testearlos sin arrancar el listener
// HTTP real de `Deno.serve`, ver response_helpers.ts).
// NOTA: sin ejecutar con `deno test` en esta sesión (Deno no disponible) --
// ver resumen final.
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { GeminiHttpError } from "./gemini.ts";
import { SHARED_QUOTA_EXHAUSTED_MESSAGE, buildUserDataBlock, mapGeminiError, sanitizeIdsToRemove } from "./response_helpers.ts";
import type { ParsedAiRequest } from "./validate_request.ts";

function baseParsed(overrides: Partial<ParsedAiRequest> = {}): ParsedAiRequest {
  return { action: "create_playlist", prompt: "", contextTracks: [], params: {}, ...overrides };
}

Deno.test("buildUserDataBlock: incluye solo los campos presentes, sin claves undefined", () => {
  const block = buildUserDataBlock(baseParsed({ prompt: "algo relajado" }));
  assertEquals(block, { prompt: "algo relajado" });
});

Deno.test("buildUserDataBlock: agrega requestedCount, interleave, params y contextTracks cuando existen", () => {
  const block = buildUserDataBlock(
    baseParsed({
      prompt: "x",
      count: 25,
      interleave: true,
      params: { genre: "rock" },
      contextTracks: [{ id: "1", title: "A", artist: "B" }],
    }),
  );
  assertEquals(block, {
    prompt: "x",
    requestedCount: 25,
    interleave: true,
    params: { genre: "rock" },
    contextTracks: [{ id: "1", title: "A", artist: "B" }],
  });
});

Deno.test("buildUserDataBlock: contextTracks sin id (create_playlist/queue) no incluye la clave id", () => {
  const block = buildUserDataBlock(baseParsed({ contextTracks: [{ title: "A", artist: "B" }] }));
  assertEquals(block.contextTracks, [{ title: "A", artist: "B" }]);
});

Deno.test("sanitizeIdsToRemove: deja pasar solo ids dentro del conjunto permitido (D-7)", () => {
  const result = sanitizeIdsToRemove({ idsToRemove: ["1", "2", "no-existe"] }, ["1", "2", "3"]);
  assertEquals(result, { idsToRemove: ["1", "2"] });
});

Deno.test("sanitizeIdsToRemove: descarta valores que no son string aunque el schema debería haberlo evitado", () => {
  const result = sanitizeIdsToRemove({ idsToRemove: ["1", 2, null] as unknown[] }, ["1", "2"]);
  assertEquals(result, { idsToRemove: ["1"] });
});

Deno.test("mapGeminiError: 429 + llave compartida -> shared_quota_exhausted con el mensaje exacto del plan", async () => {
  const response = mapGeminiError(new GeminiHttpError(429, "quota exceeded"), true);
  assertEquals(response.status, 429);
  const body = await response.json();
  assertEquals(body.error, "shared_quota_exhausted");
  assertEquals(body.message, SHARED_QUOTA_EXHAUSTED_MESSAGE);
});

Deno.test("mapGeminiError: 429 + BYOK -> byok_upstream_error, NUNCA shared_quota_exhausted", async () => {
  const response = mapGeminiError(new GeminiHttpError(429, "quota exceeded"), false);
  const body = await response.json();
  assertEquals(body.error, "byok_upstream_error");
});

Deno.test("mapGeminiError: error no-429 + llave compartida -> upstream_error", async () => {
  const response = mapGeminiError(new GeminiHttpError(500, "server error"), true);
  const body = await response.json();
  assertEquals(body.error, "upstream_error");
});

Deno.test("mapGeminiError: error no-429 + BYOK -> byok_upstream_error", async () => {
  const response = mapGeminiError(new GeminiHttpError(400, "bad request"), false);
  const body = await response.json();
  assertEquals(body.error, "byok_upstream_error");
});

Deno.test("mapGeminiError: error que no es GeminiHttpError (ej. JSON inválido) -> invalid_ai_response", async () => {
  const response = mapGeminiError(new Error("output_text no es JSON válido"), true);
  const body = await response.json();
  assertEquals(body.error, "invalid_ai_response");
});
