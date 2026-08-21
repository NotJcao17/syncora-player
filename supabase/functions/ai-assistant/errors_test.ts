// Fase 7.E.9 -- tests del contrato de error (7.E.3b): status HTTP correcto
// por código, y que los dos códigos que la UI debe distinguir sean
// exactamente los que pide el plan.
// NOTA: sin ejecutar con `deno test` en esta sesión (Deno no disponible) --
// ver resumen final.
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { errorResponse } from "./errors.ts";

async function bodyOf(response: Response): Promise<{ error: string; message: string }> {
  return await response.json();
}

Deno.test("rate_limited_user: HTTP 429, sin mencionar la llave compartida", async () => {
  const response = errorResponse("rate_limited_user", "Espera un momento e intenta de nuevo.");
  assertEquals(response.status, 429);
  const body = await bodyOf(response);
  assertEquals(body.error, "rate_limited_user");
  assertEquals(body.message.toLowerCase().includes("compartida"), false);
});

Deno.test("shared_quota_exhausted: HTTP 429, con el mensaje exacto del plan", async () => {
  const message =
    "La IA gratuita de la app se agotó por hoy — ingresa tu propia API key gratuita de Gemini para " +
    "seguir usando esta función.";
  const response = errorResponse("shared_quota_exhausted", message);
  assertEquals(response.status, 429);
  const body = await bodyOf(response);
  assertEquals(body.error, "shared_quota_exhausted");
  assertEquals(body.message, message);
});

Deno.test("rate_limited_user y shared_quota_exhausted son códigos distintos aunque compartan status 429", () => {
  // El cliente Dart (7.E.7) debe poder distinguirlos por `error`, no por
  // status HTTP -- ambos son 429 a propósito (son formas de "vuelve más
  // tarde"), la diferencia semántica vive en el campo `error`.
  const a = errorResponse("rate_limited_user", "a");
  const b = errorResponse("shared_quota_exhausted", "b");
  assertEquals(a.status, b.status);
});

Deno.test("invalid_request: HTTP 400", async () => {
  const response = errorResponse("invalid_request", "bad body");
  assertEquals(response.status, 400);
});

Deno.test("unauthorized: HTTP 401", async () => {
  const response = errorResponse("unauthorized", "no jwt");
  assertEquals(response.status, 401);
});

Deno.test("server_misconfigured: HTTP 500", async () => {
  const response = errorResponse("server_misconfigured", "missing secret");
  assertEquals(response.status, 500);
});

Deno.test("upstream_error / byok_upstream_error / invalid_ai_response: HTTP 502", () => {
  assertEquals(errorResponse("upstream_error", "x").status, 502);
  assertEquals(errorResponse("byok_upstream_error", "x").status, 502);
  assertEquals(errorResponse("invalid_ai_response", "x").status, 502);
});

Deno.test("todas las respuestas de error incluyen los headers CORS", () => {
  const response = errorResponse("invalid_request", "x");
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), "*");
});
