// Fase 7.E -- Edge Function única de infraestructura de IA (Documento
// Maestro §4.3, docs/plan_fase_7.md sección 7.E). Base de las 4 funciones de
// IA de la Fase 7.F (que NO se implementan aquí, solo el schema/infra).
//
// Reglas de seguridad no negociables (repetidas aquí a propósito, para que
// cualquiera que edite este archivo las tenga a la vista):
//   1. `GEMINI_API_KEY` es un secreto de servidor (`Deno.env.get`), nunca
//      viaja al cliente ni se loguea.
//   2. BYOK unificado: si llega `X-User-AI-Key`, se reenvía a Gemini y se
//      descarta -- nunca se persiste, nunca se loguea, nunca sale de esta
//      función hacia otro lado que no sea la llamada a Gemini.
//   3. El cliente de Supabase interno se crea SIEMPRE con el JWT del usuario
//      (header `Authorization` que Supabase ya reenvía), nunca con
//      `SERVICE_ROLE_KEY`.
//   4. Esta función NUNCA ejecuta INSERT/UPDATE/DELETE sobre datos de
//      usuario (playlists, colas, etc.) -- la única tabla en la que escribe
//      es `ai_rate_limit_requests`, que es infraestructura propia de la
//      función, no datos de usuario. Todo lo demás es de solo lectura
//      (contexto que el propio cliente ya mandó en el body) + la llamada a
//      Gemini. El `INSERT`/`DELETE`/`UPDATE` real de la sugerencia lo hace
//      el cliente Flutter, con su propio JWT, después de vista previa
//      confirmada (D-12, Fase 7.F).
//   5. Dos códigos de error diferenciados y estables (7.E.3b), nunca un 500
//      genérico para un caso esperado -- ver errors.ts.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { isAiAction } from "./actions.ts";
import { CORS_HEADERS, errorResponse, jsonResponse } from "./errors.ts";
import { callGemini } from "./gemini.ts";
import { systemPromptFor } from "./prompts.ts";
import { checkRateLimit, recordRequest, type RateLimitDb } from "./rate_limit.ts";
import { buildUserDataBlock, mapGeminiError, sanitizeIdsToRemove } from "./response_helpers.ts";
import { buildInteractionInput } from "./sanitize.ts";
import { buildResponseSchema, validateAiOutput } from "./schemas.ts";
import { ValidationError, parseAndValidateRequest, type ParsedAiRequest } from "./validate_request.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return errorResponse("invalid_request", "Método no soportado, usa POST");
  }

  try {
    return await handleRequest(req);
  } catch (error) {
    // Nunca se loguea `req` completo (podría contener el header
    // X-User-AI-Key) -- solo el mensaje del error.
    console.error("ai-assistant: error no anticipado", error instanceof Error ? error.message : error);
    return errorResponse("internal_error", "Ocurrió un error inesperado. Intenta de nuevo.");
  }
});

async function handleRequest(req: Request): Promise<Response> {
  // --- 1. Parseo del body y de la acción ---------------------------------
  let rawBody: unknown;
  try {
    rawBody = await req.json();
  } catch {
    return errorResponse("invalid_request", "El cuerpo de la petición no es JSON válido");
  }

  const action = (rawBody as Record<string, unknown> | null)?.action;
  if (!isAiAction(action)) {
    return errorResponse(
      "invalid_request",
      "'action' debe ser una de: create_playlist, create_queue, modify_playlist_remove, " +
        "modify_playlist_add, lyric_search",
    );
  }

  // --- 2. Autenticación: JWT del usuario, nunca SERVICE_ROLE_KEY ---------
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return errorResponse("unauthorized", "Falta el header Authorization");
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !supabaseAnonKey) {
    return errorResponse("server_misconfigured", "La función no está configurada correctamente");
  }

  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });

  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();
  if (authError || !user) {
    return errorResponse("unauthorized", "Sesión inválida o expirada");
  }

  // --- 3. BYOK: si viene X-User-AI-Key, se usa y se omite el rate limit --
  // interno (Documento Maestro §4.3 punto 3 / plan 7.E, punto 5) -- en modo
  // BYOK el usuario consume su propia cuota de Gemini, no la compartida.
  const byokKey = req.headers.get("X-User-AI-Key")?.trim() || undefined;
  const usingSharedKey = !byokKey;

  if (usingSharedKey) {
    const rateLimit = await checkRateLimit(supabase as unknown as RateLimitDb, user.id);
    if (!rateLimit.allowed) {
      return errorResponse(
        "rate_limited_user",
        "Hiciste muchas peticiones de IA en poco tiempo. Espera unos minutos e intenta de nuevo.",
      );
    }
  }

  // --- 4. Validación/saneamiento del payload específico de la acción -----
  let parsed: ParsedAiRequest;
  try {
    parsed = parseAndValidateRequest(action, rawBody);
  } catch (error) {
    if (error instanceof ValidationError) {
      return errorResponse("invalid_request", error.message);
    }
    throw error;
  }

  // --- 5. Camino rápido: "quitar" sobre una playlist sin ids válidos -----
  // No hay nada que Gemini pueda hacer con un conjunto vacío de ids (D-7:
  // el enum del schema estaría vacío, lo cual ni siquiera es un schema
  // válido) -- se responde directo sin gastar una llamada a Gemini ni
  // contar contra el rate limit.
  if (action === "modify_playlist_remove" && parsed.contextTracks.length === 0) {
    return jsonResponse({ action, result: { idsToRemove: [] } }, 200);
  }

  // --- 6. Llave a usar: BYOK o la compartida del servidor -----------------
  const apiKey = byokKey ?? Deno.env.get("GEMINI_API_KEY");
  if (!apiKey) {
    return errorResponse("server_misconfigured", "Falta configurar la llave de Gemini en el servidor");
  }

  // Se registra el intento ANTES de llamar a Gemini (cuenta como "una
  // petición a la función", independientemente de si Gemini responde bien) --
  // solo si se está usando la llave compartida.
  if (usingSharedKey) {
    await recordRequest(supabase as unknown as RateLimitDb, user.id);
  }

  const existingIds =
    action === "modify_playlist_remove"
      ? parsed.contextTracks.map((t) => t.id).filter((id): id is string => !!id)
      : undefined;

  const schema = buildResponseSchema(action, existingIds);
  const systemPrompt = systemPromptFor(action);
  const input = buildInteractionInput(systemPrompt, buildUserDataBlock(parsed));

  let output: unknown;
  try {
    output = await callGemini({ apiKey, input, schema });
  } catch (error) {
    return mapGeminiError(error, usingSharedKey);
  }

  if (!validateAiOutput(action, output)) {
    return errorResponse(
      "invalid_ai_response",
      "La IA devolvió una respuesta con un formato inesperado. Intenta de nuevo.",
    );
  }

  if (action === "modify_playlist_remove") {
    output = sanitizeIdsToRemove(output, existingIds ?? []);
  }

  return jsonResponse({ action, result: output }, 200);
}
