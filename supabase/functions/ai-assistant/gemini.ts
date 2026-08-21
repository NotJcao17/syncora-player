// Fase 7.E.1/7.E.6 -- cliente mínimo de la API de Interactions de Gemini.
//
// H-7 (docs/plan_fase_7.md): el plan original apuntaba a `gemini-3.1-flash-lite`
// sobre el endpoint clásico `generateContent`; verificado en vivo contra
// ai.google.dev (agosto 2026) que eso cambió:
//   - `gemini-3.1-flash-lite` ya tiene fecha de baja anunciada (7 de mayo de
//     2027), con `gemini-3.5-flash-lite` como reemplazo recomendado explícito.
//   - El endpoint vigente es la API de Interactions (`v1beta/interactions`),
//     no `generateContent`/`contents`/`candidates[...]`.
// Los límites RPM/RPD/TPM exactos del free tier de `gemini-3.5-flash-lite` NO
// se verificaron en esa sesión (la tabla de límites por nivel no cargó) --
// revisar contra AI Studio antes de confiar en cifras exactas de cuota.
//
// Deliberadamente sin SDK de npm/esm.sh: solo `fetch` nativo de Deno, para no
// sumar una dependencia externa a una función que ya depende de Gemini estar
// disponible -- menos superficie de fallo.

// Único lugar del código donde se fija el modelo (7.E.6): todo lo demás lo
// referencia a través de este módulo.
export const GEMINI_MODEL = "gemini-3.5-flash-lite";

const GEMINI_INTERACTIONS_URL = "https://generativelanguage.googleapis.com/v1beta/interactions";

export class GeminiHttpError extends Error {
  readonly status: number;
  readonly bodyText: string;

  constructor(status: number, bodyText: string) {
    super(`Gemini respondió HTTP ${status}`);
    this.name = "GeminiHttpError";
    this.status = status;
    this.bodyText = bodyText;
  }
}

export interface CallGeminiParams {
  apiKey: string;
  input: string;
  schema: unknown;
}

/**
 * Llama a la API de Interactions y devuelve el JSON ya parseado desde
 * `output_text` (el campo que reemplaza a
 * `candidates[0].content.parts[0].text` del endpoint clásico). Lanza
 * `GeminiHttpError` en cualquier respuesta HTTP no exitosa -- el llamador
 * decide, según el status y si la llave era BYOK o compartida, a qué
 * `AiErrorCode` mapearlo (ver index.ts).
 */
export async function callGemini({ apiKey, input, schema }: CallGeminiParams): Promise<unknown> {
  const response = await fetch(GEMINI_INTERACTIONS_URL, {
    method: "POST",
    headers: {
      "x-goog-api-key": apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: GEMINI_MODEL,
      input,
      response_format: {
        type: "text",
        mime_type: "application/json",
        schema,
      },
    }),
  });

  const rawText = await response.text();

  if (!response.ok) {
    // NUNCA loguear `apiKey` aquí (BYOK o compartida): solo status + cuerpo
    // de la respuesta de Gemini, que no contiene la llave.
    throw new GeminiHttpError(response.status, rawText);
  }

  let parsedBody: unknown;
  try {
    parsedBody = JSON.parse(rawText);
  } catch {
    throw new Error("La respuesta de Gemini no es JSON válido");
  }

  const outputText = (parsedBody as Record<string, unknown> | null)?.output_text;
  if (typeof outputText !== "string") {
    throw new Error("La respuesta de Gemini no trae 'output_text'");
  }

  try {
    return JSON.parse(outputText);
  } catch {
    throw new Error("'output_text' de Gemini no es JSON válido");
  }
}
