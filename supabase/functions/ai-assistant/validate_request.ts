// Fase 7.E.1/7.E.5 -- parseo y validación del body por acción. Aquí también
// se aplica el saneamiento de texto libre y el tope de contexto (D-5, 7.E.5)
// antes de que nada llegue a `sanitize.ts#buildInteractionInput`.
import type { AiAction } from "./actions.ts";
import { capArray, sanitizeFreeText } from "./sanitize.ts";

export class ValidationError extends Error {}

export interface ContextTrack {
  id?: string;
  title: string;
  artist: string;
}

export interface ParsedAiRequest {
  action: AiAction;
  prompt: string;
  count?: number;
  interleave?: boolean;
  contextTracks: ContextTrack[];
  params: Record<string, unknown>;
}

// Tope duro por acción para el parámetro opcional "cantidad" que el panel de
// la Fase 7.F podrá mandar (D-5): el cliente pide ~30% de más y recorta tras
// recibir la respuesta, así que este número es el tope de lo que el USUARIO
// puede pedir, no lo que se le pide a Gemini (eso ya lo maneja
// `schemas.ts#buildResponseSchema` con su propio `maxItems`, más holgado).
const MAX_REQUESTED_COUNT: Partial<Record<AiAction, number>> = {
  create_playlist: 300,
  create_queue: 100,
  modify_playlist_add: 100,
};

function clampCount(action: AiAction, raw: unknown): number | undefined {
  if (typeof raw !== "number" || !Number.isFinite(raw)) return undefined;
  const max = MAX_REQUESTED_COUNT[action];
  if (max === undefined) return undefined;
  const intVal = Math.trunc(raw);
  if (intVal <= 0) return undefined;
  return Math.min(intVal, max);
}

function parseContextTracks(raw: unknown, requireId: boolean): ContextTrack[] {
  if (!Array.isArray(raw)) return [];
  const capped = capArray(raw);
  const parsed: ContextTrack[] = [];
  for (const entry of capped) {
    if (typeof entry !== "object" || entry === null) continue;
    const record = entry as Record<string, unknown>;
    const title = typeof record.title === "string" ? sanitizeFreeText(record.title, 200) : "";
    const artist = typeof record.artist === "string" ? sanitizeFreeText(record.artist, 200) : "";
    if (!title || !artist) continue;
    const id = typeof record.id === "string" ? record.id : undefined;
    if (requireId && !id) continue;
    parsed.push({ id, title, artist });
  }
  return parsed;
}

function parseParams(raw: unknown): Record<string, unknown> {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return {};
  const record = raw as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  // Copia superficial saneando cualquier valor string suelto (tags de
  // género/mood, etc.); el resto de tipos primitivos (número/bool) se
  // aceptan tal cual porque no representan texto libre inyectable.
  for (const [key, value] of Object.entries(record)) {
    if (typeof value === "string") {
      out[key] = sanitizeFreeText(value, 200);
    } else if (typeof value === "number" || typeof value === "boolean") {
      out[key] = value;
    } else if (Array.isArray(value)) {
      out[key] = value
        .filter((v) => typeof v === "string")
        .slice(0, 50)
        .map((v) => sanitizeFreeText(v as string, 100));
    }
    // Otros tipos (objetos anidados, etc.) se ignoran a propósito: el panel
    // de parámetros de 7.F es una lista fija y conocida de campos planos.
  }
  return out;
}

/**
 * Valida y normaliza el body crudo (ya parseado como JSON) para `action`.
 * Lanza `ValidationError` con un mensaje apto para el usuario ante cualquier
 * forma inesperada -- el caller (index.ts) lo traduce a `invalid_request`.
 */
export function parseAndValidateRequest(action: AiAction, body: unknown): ParsedAiRequest {
  if (typeof body !== "object" || body === null) {
    throw new ValidationError("El cuerpo de la petición debe ser un objeto JSON");
  }
  const record = body as Record<string, unknown>;

  const prompt = sanitizeFreeText(record.prompt);
  const count = clampCount(action, record.count);
  const interleave = typeof record.interleave === "boolean" ? record.interleave : undefined;
  const params = parseParams(record.params);

  switch (action) {
    case "create_playlist": {
      const contextTracks = parseContextTracks(record.contextTracks, false);
      if (!prompt && Object.keys(params).length === 0 && contextTracks.length === 0) {
        throw new ValidationError(
          "Escribe una descripción o elige al menos un parámetro para crear la playlist",
        );
      }
      return { action, prompt, count, contextTracks, params };
    }

    case "create_queue": {
      const contextTracks = parseContextTracks(record.contextTracks, false);
      if (!prompt && contextTracks.length === 0 && Object.keys(params).length === 0) {
        throw new ValidationError(
          "Escribe una descripción o basa la cola en una playlist/cola actual",
        );
      }
      return { action, prompt, count, interleave, contextTracks, params };
    }

    case "modify_playlist_add": {
      const contextTracks = parseContextTracks(record.contextTracks, false);
      if (!prompt && Object.keys(params).length === 0) {
        throw new ValidationError("Describe qué canciones quieres agregar");
      }
      return { action, prompt, count, contextTracks, params };
    }

    case "modify_playlist_remove": {
      // Aquí SÍ es obligatorio el id -- es lo que arma el `enum` cerrado de
      // D-7. Una entrada de contexto sin id se descarta silenciosamente en
      // `parseContextTracks`, así que si nada trae id, la playlist quedó
      // efectivamente vacía a ojos de esta acción.
      const contextTracks = parseContextTracks(record.contextTracks, true);
      if (!prompt) {
        throw new ValidationError("Describe qué canciones quieres quitar");
      }
      return { action, prompt, contextTracks, params };
    }

    case "lyric_search": {
      if (!prompt) {
        throw new ValidationError("Pega el fragmento de letra que quieres buscar");
      }
      return { action, prompt, contextTracks: [], params };
    }
  }
}
