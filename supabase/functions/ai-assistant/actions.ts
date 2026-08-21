// Fase 7.E.1/7.E.4 -- las 5 acciones que soporta la única Edge Function de IA.
//
// D-6/D-7 del plan (docs/plan_fase_7.md): "modificar playlist" son en
// realidad dos acciones separadas a nivel de schema (quitar vs. agregar),
// aunque en la UI de la Fase 7.F vivan juntas bajo un solo menú "Modificar
// playlist con IA" -- el schema restringido a IDs existentes (D-7) solo
// aplica al modo "quitar", así que necesitan `response_schema` distintos.

export const AI_ACTIONS = [
  "create_playlist",
  "create_queue",
  "modify_playlist_remove",
  "modify_playlist_add",
  "lyric_search",
] as const;

export type AiAction = (typeof AI_ACTIONS)[number];

export function isAiAction(value: unknown): value is AiAction {
  return typeof value === "string" && (AI_ACTIONS as readonly string[]).includes(value);
}
