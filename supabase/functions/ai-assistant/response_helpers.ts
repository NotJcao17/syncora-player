// Fase 7.E.1 -- helpers puros usados por index.ts, separados a un módulo
// propio a propósito: `index.ts` llama `Deno.serve(...)` como efecto de
// borde al nivel superior del archivo, así que importarlo directamente
// desde un test arrancaría un listener HTTP real. Estas funciones son
// lógica pura (sin I/O) y viven aquí para poder testearlas sin ese efecto
// de borde -- ver response_helpers_test.ts.
import { GeminiHttpError } from "./gemini.ts";
import { errorResponse, type AiErrorCode } from "./errors.ts";
import type { ParsedAiRequest } from "./validate_request.ts";

export const SHARED_QUOTA_EXHAUSTED_MESSAGE =
  "La IA gratuita de la app se agotó por hoy — ingresa tu propia API key gratuita de Gemini para " +
  "seguir usando esta función.";

/** Solo los campos relevantes para la acción, ya saneados por el validador. */
export function buildUserDataBlock(parsed: ParsedAiRequest): Record<string, unknown> {
  const block: Record<string, unknown> = { prompt: parsed.prompt };
  if (parsed.count !== undefined) block.requestedCount = parsed.count;
  if (parsed.interleave !== undefined) block.interleave = parsed.interleave;
  if (Object.keys(parsed.params).length > 0) block.params = parsed.params;
  if (parsed.contextTracks.length > 0) {
    block.contextTracks = parsed.contextTracks.map((t) =>
      t.id !== undefined ? { id: t.id, title: t.title, artist: t.artist } : { title: t.title, artist: t.artist },
    );
  }
  return block;
}

/**
 * D-7, defensa en profundidad: aunque el `response_schema` con `enum` ya
 * hace estructuralmente imposible que Gemini invente un id, nunca se confía
 * ciegamente en la salida de un modelo -- se vuelve a filtrar contra el
 * conjunto cerrado que el propio cliente mandó en esta invocación.
 */
export function sanitizeIdsToRemove(output: unknown, existingIds: string[]): { idsToRemove: string[] } {
  const allowed = new Set(existingIds);
  const record = output as { idsToRemove: unknown[] };
  const filtered = record.idsToRemove.filter((id): id is string => typeof id === "string" && allowed.has(id));
  return { idsToRemove: filtered };
}

/**
 * Traduce un fallo al llamar a Gemini al código de error diferenciado que
 * corresponde (7.E.3b): la distinción clave es BYOK vs. llave compartida, y
 * dentro de la llave compartida, si el 429 es *nuestra* cuota diaria
 * agotada (`shared_quota_exhausted`, mensaje exacto del plan) o cualquier
 * otro fallo upstream (`upstream_error`, genérico).
 */
export function mapGeminiError(error: unknown, usingSharedKey: boolean): Response {
  if (error instanceof GeminiHttpError) {
    if (error.status === 429) {
      if (usingSharedKey) {
        return errorResponse("shared_quota_exhausted", SHARED_QUOTA_EXHAUSTED_MESSAGE);
      }
      return errorResponse(
        "byok_upstream_error",
        "Tu propia llave de Gemini alcanzó su límite de uso por ahora. Intenta de nuevo más tarde " +
          "o revisa tu cuota en Google AI Studio.",
      );
    }
    if (usingSharedKey) {
      return errorResponse(
        "upstream_error",
        "La IA no está disponible en este momento. Intenta de nuevo en unos minutos.",
      );
    }
    return errorResponse(
      "byok_upstream_error",
      "Tu llave de Gemini devolvió un error al procesar la solicitud. Verifica que sea válida.",
    );
  }

  // Cualquier otro fallo (red, timeout, JSON inválido de `output_text`,
  // etc.) se trata como respuesta de IA inválida/no disponible, nunca como
  // 500 genérico.
  return errorResponse(
    "invalid_ai_response",
    "No se pudo interpretar la respuesta de la IA. Intenta de nuevo.",
  );
}

export type { AiErrorCode };
