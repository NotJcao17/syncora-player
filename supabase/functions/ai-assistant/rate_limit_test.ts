// Fase 7.E.9 -- tests de la lógica de rate limit contra un doble de prueba
// de la tabla (sin red real, sin BD real -- ver `RateLimitDb` en
// rate_limit.ts, pensado justo para poder inyectar este tipo de doble).
// NOTA: sin ejecutar con `deno test` en esta sesión (Deno no disponible) --
// ver resumen final.
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { SHARED_KEY_HOURLY_LIMIT, checkRateLimit, recordRequest, type RateLimitDb } from "./rate_limit.ts";

/** Doble de prueba en memoria de la tabla `ai_rate_limit_requests`. */
function fakeDb(rows: { user_id: string; requested_at: string }[]): RateLimitDb & { rows: typeof rows } {
  return {
    rows,
    from(_table: string) {
      return {
        select: (_columns: string, _opts?: { count?: "exact"; head?: boolean }) => ({
          eq: (_col: string, userId: string) => ({
            gt: async (_col2: string, since: string) => {
              const count = rows.filter((r) => r.user_id === userId && r.requested_at > since).length;
              return { count, error: null };
            },
          }),
        }),
        insert: async (row: Record<string, unknown>) => {
          rows.push({ user_id: row.user_id as string, requested_at: new Date().toISOString() });
          return { error: null };
        },
      };
    },
  };
}

Deno.test("checkRateLimit: permite la petición si está por debajo del límite", async () => {
  const db = fakeDb([{ user_id: "u1", requested_at: new Date().toISOString() }]);
  const result = await checkRateLimit(db, "u1");
  assertEquals(result.allowed, true);
  assertEquals(result.count, 1);
});

Deno.test("checkRateLimit: bloquea justo al llegar al límite (>= no >)", async () => {
  const now = Date.now();
  const rows = Array.from({ length: SHARED_KEY_HOURLY_LIMIT }, (_, i) => ({
    user_id: "u1",
    requested_at: new Date(now - i * 1000).toISOString(),
  }));
  const db = fakeDb(rows);
  const result = await checkRateLimit(db, "u1");
  assertEquals(result.allowed, false);
  assertEquals(result.count, SHARED_KEY_HOURLY_LIMIT);
});

Deno.test("checkRateLimit: solo cuenta filas dentro de la ventana de 1 hora", async () => {
  const now = Date.now();
  const rows = [
    { user_id: "u1", requested_at: new Date(now - 30 * 60 * 1000).toISOString() }, // hace 30 min: cuenta
    { user_id: "u1", requested_at: new Date(now - 2 * 60 * 60 * 1000).toISOString() }, // hace 2h: no cuenta
  ];
  const db = fakeDb(rows);
  const result = await checkRateLimit(db, "u1");
  assertEquals(result.count, 1);
});

Deno.test("checkRateLimit: el límite es por usuario, no global", async () => {
  const now = new Date().toISOString();
  const rows = Array.from({ length: SHARED_KEY_HOURLY_LIMIT }, () => ({ user_id: "u1", requested_at: now }));
  const db = fakeDb(rows);
  const resultOtherUser = await checkRateLimit(db, "u2");
  assertEquals(resultOtherUser.allowed, true);
  assertEquals(resultOtherUser.count, 0);
});

Deno.test("recordRequest: agrega una fila nueva para el usuario", async () => {
  const db = fakeDb([]);
  await recordRequest(db, "u1");

  assertEquals(db.rows.length, 1);
  assertEquals(db.rows[0].user_id, "u1");
});

// Fase 7.E (fix de seguridad post-review): `recordRequest` YA NO poda filas
// viejas -- la primera versión lo hacía con el JWT del usuario, lo cual
// requería una política RLS de DELETE que un cliente cualquiera podía usar
// directamente (sin pasar por la Edge Function) para borrar su propio
// historial y resetear su cupo a voluntad. Este test fija ese comportamiento:
// filas viejas de OTRAS peticiones deben sobrevivir a `recordRequest` sin
// que nada las borre -- la poda queda pendiente de un cron de servidor
// (fuera del alcance de este módulo, ver rate_limit.ts y la migración).
Deno.test("recordRequest: NO borra filas viejas del mismo usuario (ya no poda -- fix de seguridad)", async () => {
  const now = Date.now();
  const oldRow = { user_id: "u1", requested_at: new Date(now - 2 * 60 * 60 * 1000).toISOString() };
  const db = fakeDb([oldRow]);

  await recordRequest(db, "u1");

  assertEquals(db.rows.length, 2);
  assertEquals(db.rows.includes(oldRow), true);
});

Deno.test("RateLimitDb: la interfaz no expone ningún método delete (fix de seguridad: nadie debe poder borrar rate limit con el JWT del usuario)", () => {
  const db = fakeDb([]);
  assertEquals("delete" in db.from("ai_rate_limit_requests"), false);
});
