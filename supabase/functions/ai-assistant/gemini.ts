// Fase 7.E.1/7.E.6 -- cliente mínimo de la API de Gemini (`generateContent`).
//
// CORRECCIÓN (post-Fase 7, encontrada en pruebas manuales): H-7
// (docs/plan_fase_7.md) documentaba un endpoint "API de Interactions"
// (`v1beta/interactions`) que se daba por "verificado en vivo" contra
// ai.google.dev en agosto 2026. En la práctica, desplegado contra el
// proyecto real, **cada** llamada a Gemini fallaba con un error HTTP (tanto
// con la llave compartida como con BYOK) -- el endpoint no existe. No hay
// ninguna "API de Interactions" documentada públicamente para Gemini; el
// endpoint real y estable para salida estructurada es
// `v1beta/models/{model}:generateContent` con
// `generationConfig.responseMimeType`/`responseSchema`, vigente desde antes
// de la Fase 7 y sin fecha de baja anunciada. H-7 quedó como un hallazgo
// erróneo de una sesión de planeación anterior -- se corrige acá.
//
// El identificador de modelo (`gemini-3.5-flash-lite`) NO se toca en esta
// corrección -- esa parte de H-7 (versión del modelo, no el endpoint) no
// tiene evidencia en contra.
//
// Deliberadamente sin SDK de npm/esm.sh: solo `fetch` nativo de Deno, para no
// sumar una dependencia externa a una función que ya depende de Gemini estar
// disponible -- menos superficie de fallo.

// Único lugar del código donde se fija el modelo (7.E.6): todo lo demás lo
// referencia a través de este módulo.
export const GEMINI_MODEL = "gemini-3.5-flash-lite";

/**
 * Modelo para `lyric_search` (2026-10-08). El Lite casi no reconoce letras de
 * memoria y la búsqueda de Google (grounding) **no está disponible en el plan
 * gratuito** de Gemini (ai.google.dev/gemini-api/docs/pricing: "Not
 * available" en la columna Free Tier), así que el intento con búsqueda
 * fallaba siempre y caía al Lite sin ella. Flash recuerda muchas más letras;
 * si falla (cuota del día, modelo no disponible), index.ts repite con
 * [GEMINI_MODEL].
 */
export const GEMINI_LYRICS_MODEL = "gemini-3.8-flash";

function generateContentUrl(model: string): string {
  return `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`;
}

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
  /** Por defecto [GEMINI_MODEL]. */
  model?: string;
}

/**
 * Llama a `generateContent` y devuelve el JSON ya parseado desde
 * `candidates[0].content.parts[0].text` (con `responseMimeType:
 * "application/json"` en `generationConfig`, Gemini garantiza que ese texto
 * es JSON válido conforme a `responseSchema`). Lanza `GeminiHttpError` en
 * cualquier respuesta HTTP no exitosa -- el llamador decide, según el status
 * y si la llave era BYOK o compartida, a qué `AiErrorCode` mapearlo (ver
 * index.ts).
 */
export async function callGemini({ apiKey, input, schema, model = GEMINI_MODEL }: CallGeminiParams): Promise<unknown> {
  const response = await fetch(generateContentUrl(model), {
    method: "POST",
    headers: {
      "x-goog-api-key": apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      contents: [{ parts: [{ text: input }] }],
      generationConfig: {
        responseMimeType: "application/json",
        responseSchema: schema,
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

  const candidates = (parsedBody as Record<string, unknown> | null)?.candidates;
  const firstCandidate = Array.isArray(candidates) ? (candidates[0] as Record<string, unknown> | undefined) : undefined;
  const content = firstCandidate?.content as Record<string, unknown> | undefined;
  const parts = content?.parts;
  // La respuesta puede venir repartida en varias partes de texto (p. ej. con
  // modelos que razonan): se unen todas en vez de leer solo la primera.
  const outputText = Array.isArray(parts)
    ? parts
      .map((p) => (p as Record<string, unknown> | undefined)?.text)
      .filter((t): t is string => typeof t === "string")
      .join("")
    : undefined;

  if (!outputText) {
    throw new Error("La respuesta de Gemini no trae texto en 'candidates[0].content.parts'");
  }

  // Algunos modelos envuelven el JSON en un bloque de código aunque se pida
  // JSON puro.
  const unfenced = outputText.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");

  try {
    return JSON.parse(unfenced);
  } catch {
    throw new Error("El texto de salida de Gemini no es JSON válido");
  }
}
