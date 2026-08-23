// Fase 7.E.4 -- `responseSchema` de las 5 acciones, en el subconjunto de
// JSON Schema que acepta `generationConfig.responseSchema` de Gemini (string
// / number / integer / boolean / object / array / null, con enum, format,
// required, properties, items, minItems/maxItems, minimum/maximum -- ver H-7
// en docs/plan_fase_7.md). Estas formas las reutiliza también la Fase 7.F, así
// que se mantienen estables y simples: `{title, artist}` es lo mínimo que
// necesita el matching contra Deezer (D-8), nunca ids ni portadas inventadas.
import type { AiAction } from "./actions.ts";

export interface JsonSchema {
  type: string;
  properties?: Record<string, JsonSchema>;
  items?: JsonSchema;
  required?: string[];
  enum?: string[];
  minItems?: number;
  maxItems?: number;
}

const TRACK_SUGGESTION_SCHEMA: JsonSchema = {
  type: "object",
  properties: {
    title: { type: "string" },
    artist: { type: "string" },
  },
  required: ["title", "artist"],
};

function tracksListSchema(maxItems: number): JsonSchema {
  return {
    type: "object",
    properties: {
      tracks: {
        type: "array",
        items: TRACK_SUGGESTION_SCHEMA,
        maxItems,
      },
    },
    required: ["tracks"],
  };
}

const CREATE_PLAYLIST_SCHEMA: JsonSchema = {
  type: "object",
  properties: {
    playlistName: { type: "string" },
    description: { type: "string" },
    tracks: {
      type: "array",
      items: TRACK_SUGGESTION_SCHEMA,
      maxItems: 400, // D-5: tope duro de la UI es 300 + margen del ~30% pedido de más.
    },
  },
  required: ["playlistName", "description", "tracks"],
};

const LYRIC_SEARCH_SCHEMA: JsonSchema = {
  type: "object",
  properties: {
    songs: {
      type: "array",
      items: TRACK_SUGGESTION_SCHEMA,
      maxItems: 10,
    },
  },
  required: ["songs"],
};

/**
 * D-7: para "quitar canciones" el `response_schema` restringe estructuralmente
 * la salida a IDs que ya vinieron en la petición -- `enum` construido en
 * caliente a partir de esa invocación particular. Es imposible que Gemini
 * devuelva un id que no esté en `existingIds`, porque no sería una salida
 * válida contra el schema.
 */
function modifyPlaylistRemoveSchema(existingIds: string[]): JsonSchema {
  return {
    type: "object",
    properties: {
      idsToRemove: {
        type: "array",
        items: { type: "string", enum: existingIds },
        maxItems: existingIds.length,
      },
    },
    required: ["idsToRemove"],
  };
}

/**
 * Construye el `response_schema` para una acción. `existingIds` solo se usa
 * (y es obligatorio) para `modify_playlist_remove`.
 */
export function buildResponseSchema(action: AiAction, existingIds?: string[]): JsonSchema {
  switch (action) {
    case "create_playlist":
      return CREATE_PLAYLIST_SCHEMA;
    case "create_queue":
      return tracksListSchema(130); // tope UI 100 + margen D-5.
    case "modify_playlist_add":
      return tracksListSchema(130); // tope UI 100 por operación (7.F.3) + margen D-5.
    case "modify_playlist_remove":
      return modifyPlaylistRemoveSchema(existingIds ?? []);
    case "lyric_search":
      return LYRIC_SEARCH_SCHEMA;
  }
}

export interface TrackSuggestion {
  title: string;
  artist: string;
}

function isTrackSuggestion(value: unknown): value is TrackSuggestion {
  return (
    typeof value === "object" &&
    value !== null &&
    typeof (value as Record<string, unknown>).title === "string" &&
    typeof (value as Record<string, unknown>).artist === "string"
  );
}

function isTrackSuggestionArray(value: unknown): value is TrackSuggestion[] {
  return Array.isArray(value) && value.every(isTrackSuggestion);
}

/**
 * Verificación de forma (no un validador de JSON Schema completo) de que la
 * salida de Gemini realmente cumple el contrato esperado para `action`.
 * Defensa en profundidad: el `responseSchema` ya se lo pedimos a Gemini,
 * pero cumplirlo es best-effort del lado del modelo, así que nunca se
 * confía ciegamente en el texto de salida sin revalidar del lado servidor
 * antes de reenviarlo al cliente.
 */
export function validateAiOutput(action: AiAction, output: unknown): boolean {
  if (typeof output !== "object" || output === null) return false;
  const obj = output as Record<string, unknown>;

  switch (action) {
    case "create_playlist":
      return (
        typeof obj.playlistName === "string" &&
        typeof obj.description === "string" &&
        isTrackSuggestionArray(obj.tracks)
      );
    case "create_queue":
    case "modify_playlist_add":
      return isTrackSuggestionArray(obj.tracks);
    case "lyric_search":
      return isTrackSuggestionArray(obj.songs);
    case "modify_playlist_remove":
      return Array.isArray(obj.idsToRemove) && obj.idsToRemove.every((v) => typeof v === "string");
  }
}
