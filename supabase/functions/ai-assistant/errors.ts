// Fase 7.E.1/7.E.3b -- contrato de error de la Edge Function de IA.
//
// La función NUNCA responde un 500 genérico para un caso esperado: cada
// situación reconocible tiene un `code` propio y estable que el cliente Dart
// (7.E.7, lib/data/services/ai_assistant_service.dart) puede mapear 1:1 a un
// `AiErrorCode` sin parsear mensajes de texto. Los dos códigos que el plan
// pide distinguir explícitamente en la UI son `rate_limited_user` y
// `shared_quota_exhausted`; el resto existen para que ningún camino de error
// caiga en un 500 sin explicación, pero 7.F no tiene por qué reaccionar a
// todos ellos de forma distinta.
export type AiErrorCode =
  | "invalid_request" // body/acción/payload mal formado.
  | "unauthorized" // falta o es inválido el JWT del header Authorization.
  | "rate_limited_user" // límite personal por hora agotado (llave compartida).
  | "shared_quota_exhausted" // cuota diaria de la llave compartida de Gemini agotada.
  | "byok_upstream_error" // Gemini devolvió error usando la llave propia del usuario.
  | "upstream_error" // Gemini devolvió error usando la llave compartida (no es cuota).
  | "invalid_ai_response" // Gemini respondió pero no cumple el response_schema esperado.
  | "server_misconfigured" // falta el secreto GEMINI_API_KEY en el servidor.
  | "internal_error"; // cualquier otro fallo no anticipado.

export interface AiErrorBody {
  error: AiErrorCode;
  message: string;
}

const STATUS_BY_CODE: Record<AiErrorCode, number> = {
  invalid_request: 400,
  unauthorized: 401,
  rate_limited_user: 429,
  shared_quota_exhausted: 429,
  byok_upstream_error: 502,
  upstream_error: 502,
  invalid_ai_response: 502,
  server_misconfigured: 500,
  internal_error: 500,
};

// CORS abierto de solo-lectura de metadatos de request: la función solo
// acepta JWT válido (verificado dentro del handler) como control de acceso
// real, así que un origin amplio aquí no relaja esa protección -- es el
// mismo patrón que usan las plantillas oficiales de Supabase Edge Functions.
export const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-user-ai-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function jsonResponse(body: unknown, status: number, extraHeaders?: HeadersInit): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...CORS_HEADERS,
      "Content-Type": "application/json",
      ...extraHeaders,
    },
  });
}

export function errorResponse(code: AiErrorCode, message: string): Response {
  const body: AiErrorBody = { error: code, message };
  return jsonResponse(body, STATUS_BY_CODE[code]);
}
