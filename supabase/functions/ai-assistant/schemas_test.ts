// Fase 7.E.9 -- tests de la construcción de `response_schema` por acción,
// en particular el `enum` dinámico de D-7 (modify_playlist_remove) y la
// validación de forma de la salida de Gemini.
// NOTA: sin ejecutar con `deno test` en esta sesión (Deno no disponible) --
// ver resumen final.
import { assertEquals, assertFalse } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { buildResponseSchema, validateAiOutput } from "./schemas.ts";

Deno.test("buildResponseSchema(modify_playlist_remove): el enum de idsToRemove es EXACTAMENTE el set recibido", () => {
  const schema = buildResponseSchema("modify_playlist_remove", ["id-1", "id-2", "id-3"]);
  const idsSchema = schema.properties?.idsToRemove;
  assertEquals(idsSchema?.items?.enum, ["id-1", "id-2", "id-3"]);
});

Deno.test("buildResponseSchema(modify_playlist_remove): sin ids existentes, el enum queda vacío (estructuralmente imposible elegir algo)", () => {
  const schema = buildResponseSchema("modify_playlist_remove", []);
  assertEquals(schema.properties?.idsToRemove?.items?.enum, []);
});

Deno.test("buildResponseSchema: create_playlist exige playlistName, description y tracks", () => {
  const schema = buildResponseSchema("create_playlist");
  assertEquals(schema.required, ["playlistName", "description", "tracks"]);
});

Deno.test("buildResponseSchema: create_queue y modify_playlist_add comparten la misma forma {tracks}", () => {
  const queueSchema = buildResponseSchema("create_queue");
  const addSchema = buildResponseSchema("modify_playlist_add");
  assertEquals(queueSchema.required, ["tracks"]);
  assertEquals(addSchema.required, ["tracks"]);
});

Deno.test("buildResponseSchema: lyric_search exige songs", () => {
  const schema = buildResponseSchema("lyric_search");
  assertEquals(schema.required, ["songs"]);
});

Deno.test("validateAiOutput: create_playlist válido", () => {
  const output = {
    playlistName: "Noche de indie",
    description: "Una mezcla tranquila",
    tracks: [{ title: "A", artist: "B" }],
  };
  assertEquals(validateAiOutput("create_playlist", output), true);
});

Deno.test("validateAiOutput: create_playlist inválido (falta description)", () => {
  const output = { playlistName: "X", tracks: [] };
  assertFalse(validateAiOutput("create_playlist", output));
});

Deno.test("validateAiOutput: create_playlist inválido (track sin artist)", () => {
  const output = {
    playlistName: "X",
    description: "Y",
    tracks: [{ title: "Solo título" }],
  };
  assertFalse(validateAiOutput("create_playlist", output));
});

Deno.test("validateAiOutput: modify_playlist_remove válido con array vacío", () => {
  assertEquals(validateAiOutput("modify_playlist_remove", { idsToRemove: [] }), true);
});

Deno.test("validateAiOutput: modify_playlist_remove inválido si idsToRemove no es array de strings", () => {
  assertFalse(validateAiOutput("modify_playlist_remove", { idsToRemove: [1, 2] }));
  assertFalse(validateAiOutput("modify_playlist_remove", { idsToRemove: "not-an-array" }));
});

Deno.test("validateAiOutput: lyric_search válido", () => {
  const output = { songs: [{ title: "A", artist: "B" }] };
  assertEquals(validateAiOutput("lyric_search", output), true);
});

Deno.test("validateAiOutput: rechaza salidas que no son objetos", () => {
  assertFalse(validateAiOutput("lyric_search", null));
  assertFalse(validateAiOutput("lyric_search", "songs: []"));
  assertFalse(validateAiOutput("lyric_search", [1, 2, 3]));
});
