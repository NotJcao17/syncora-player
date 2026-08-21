// Fase 7.E.9 -- tests de validación/normalización de body por acción.
// NOTA: sin ejecutar con `deno test` en esta sesión (Deno no disponible) --
// ver resumen final.
import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { ValidationError, parseAndValidateRequest } from "./validate_request.ts";

Deno.test("create_playlist: falla sin prompt, params ni contexto", () => {
  assertThrows(() => parseAndValidateRequest("create_playlist", {}), ValidationError);
});

Deno.test("create_playlist: pasa con solo un prompt", () => {
  const result = parseAndValidateRequest("create_playlist", { prompt: "música para estudiar" });
  assertEquals(result.prompt, "música para estudiar");
  assertEquals(result.contextTracks, []);
});

Deno.test("create_playlist: pasa con solo params (sin prompt)", () => {
  const result = parseAndValidateRequest("create_playlist", { params: { genre: "rock" } });
  assertEquals(result.prompt, "");
  assertEquals(result.params, { genre: "rock" });
});

Deno.test("create_playlist: count se recorta al tope duro de 300", () => {
  const result = parseAndValidateRequest("create_playlist", { prompt: "x", count: 5000 });
  assertEquals(result.count, 300);
});

Deno.test("create_playlist: count negativo o cero se descarta (undefined)", () => {
  assertEquals(parseAndValidateRequest("create_playlist", { prompt: "x", count: -5 }).count, undefined);
  assertEquals(parseAndValidateRequest("create_playlist", { prompt: "x", count: 0 }).count, undefined);
});

Deno.test("create_queue: count se recorta al tope duro de 100", () => {
  const result = parseAndValidateRequest("create_queue", { prompt: "x", count: 500 });
  assertEquals(result.count, 100);
});

Deno.test("modify_playlist_remove: exige prompt", () => {
  assertThrows(
    () => parseAndValidateRequest("modify_playlist_remove", { contextTracks: [{ id: "1", title: "A", artist: "B" }] }),
    ValidationError,
  );
});

Deno.test("modify_playlist_remove: descarta entradas de contexto sin id", () => {
  const result = parseAndValidateRequest("modify_playlist_remove", {
    prompt: "quita las de X",
    contextTracks: [
      { id: "1", title: "A", artist: "B" },
      { title: "Sin id", artist: "C" }, // debe descartarse
    ],
  });
  assertEquals(result.contextTracks.length, 1);
  assertEquals(result.contextTracks[0].id, "1");
});

Deno.test("modify_playlist_remove: contexto vacío es válido (playlist sin pistas)", () => {
  const result = parseAndValidateRequest("modify_playlist_remove", { prompt: "quita todo" });
  assertEquals(result.contextTracks, []);
});

Deno.test("lyric_search: exige el fragmento de letra", () => {
  assertThrows(() => parseAndValidateRequest("lyric_search", {}), ValidationError);
  assertThrows(() => parseAndValidateRequest("lyric_search", { prompt: "   " }), ValidationError);
});

Deno.test("lyric_search: pasa con un fragmento no vacío", () => {
  const result = parseAndValidateRequest("lyric_search", { prompt: "y en tu cintura un sol" });
  assertEquals(result.prompt, "y en tu cintura un sol");
});

Deno.test("params: solo copia tipos primitivos esperados, ignora objetos anidados", () => {
  const result = parseAndValidateRequest("create_playlist", {
    prompt: "x",
    params: { genre: "pop", count: 10, weird: { nested: true }, tags: ["a", "b"] },
  });
  assertEquals(result.params.genre, "pop");
  assertEquals(result.params.count, 10);
  assertEquals(result.params.tags, ["a", "b"]);
  assertEquals("weird" in result.params, false);
});

Deno.test("contextTracks: se descarta cualquier entrada sin title o artist", () => {
  const result = parseAndValidateRequest("create_queue", {
    contextTracks: [
      { title: "A", artist: "B" },
      { title: "Solo título" },
      { artist: "Solo artista" },
    ],
  });
  assertEquals(result.contextTracks.length, 1);
});
