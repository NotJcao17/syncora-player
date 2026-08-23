// Fase 7.E.4 -- `responseSchema` de las 5 acciones. NO es JSON Schema
// estándar pese al nombre del tipo de abajo: Gemini expone `Schema` como
// serialización JSON de un proto con un enum `Type`
// (STRING/NUMBER/INTEGER/BOOLEAN/ARRAY/OBJECT/NULL), así que los valores de
// `type` van en MAYÚSCULA -- corrección real (pruebas manuales): con los
// valores en minúscula ("object"/"string"/"array", la convención de JSON
// Schema estándar que parecía razonable al escribir esto originalmente),
// Gemini rechazaba el schema en el 100% de las llamadas, con la llave
// compartida y con BYOK por igual -- el mismo síntoma en ambos casos tenía
// sentido porque el bug no dependía de la llave, sino del cuerpo enviado.
//
// Corrección #2 (misma sesión, mismo síntoma): tras arreglar el `type` en
// mayúscula, Gemini seguía rechazando el 100% de las llamadas, ahora con
// `400 INVALID_ARGUMENT` genérico (sin detalle de qué campo). Verificado
// contra la documentación real (`ai.google.dev/api/generate-content`) que
// `type`/`properties`/`items`/`required` sí son campos confirmados del tipo
// `Schema` -- pero no se pudo confirmar (ni descartar) que `minItems`/
// `maxItems` lo sean, y son los únicos dos campos presentes en las 4
// acciones SIN excepción -- el candidato más probable a una falla universal.
// Se quitan acá: D-5 ya recorta el resultado al número exacto pedido de
// forma programática después de la respuesta ("nunca confiar en el prompt/
// schema solo"), así que nunca fueron necesarios para la corrección, solo
// una pista adicional para el modelo. `enum` se mantiene -- es needed para
// D-7 (que Gemini no pueda inventar un id a borrar) y si el problema
// hubiera sido `enum`, solo `modify_playlist_remove` habría fallado, no las
// 4 acciones por igual.
import type { AiAction } from "./actions.ts";

export interface JsonSchema {
  type: string;
  properties?: Record<string, JsonSchema>;
  items?: JsonSchema;
  required?: string[];
  enum?: string[];
}

const TRACK_SUGGESTION_SCHEMA: JsonSchema = {
  type: "OBJECT",
  properties: {
    title: { type: "STRING" },
    artist: { type: "STRING" },
  },
  required: ["title", "artist"],
};

function tracksListSchema(): JsonSchema {
  return {
    type: "OBJECT",
    properties: {
      tracks: {
        type: "ARRAY",
        items: TRACK_SUGGESTION_SCHEMA,
      },
    },
    required: ["tracks"],
  };
}

const CREATE_PLAYLIST_SCHEMA: JsonSchema = {
  type: "OBJECT",
  properties: {
    playlistName: { type: "STRING" },
    description: { type: "STRING" },
    tracks: {
      type: "ARRAY",
      items: TRACK_SUGGESTION_SCHEMA,
    },
  },
  required: ["playlistName", "description", "tracks"],
};

const LYRIC_SEARCH_SCHEMA: JsonSchema = {
  type: "OBJECT",
  properties: {
    songs: {
      type: "ARRAY",
      items: TRACK_SUGGESTION_SCHEMA,
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
    type: "OBJECT",
    properties: {
      idsToRemove: {
        type: "ARRAY",
        items: { type: "STRING", enum: existingIds },
      },
    },
    required: ["idsToRemove"],
  };
}

/**
 * Construye el `response_schema` para una acción. `existingIds` solo se usa
 * (y es obligatorio) para `modify_playlist_remove`. Los topes numéricos
 * (25/50/100/300, D-5) ya no viajan en el schema (ver nota de arriba) --
 * se aplican programáticamente sobre la respuesta en
 * `playlist_import_export_service.dart` (`trimToCount`).
 */
export function buildResponseSchema(action: AiAction, existingIds?: string[]): JsonSchema {
  switch (action) {
    case "create_playlist":
      return CREATE_PLAYLIST_SCHEMA;
    case "create_queue":
      return tracksListSchema();
    case "modify_playlist_add":
      return tracksListSchema();
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
