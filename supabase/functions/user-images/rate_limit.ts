// Rate limit de subidas por usuario. Mismo diseño que el de `ai-assistant`
// (registro de eventos con ventana deslizante; ver migraciones 8 y 19): sin
// permiso de DELETE, nadie puede resetear su propio cupo. El tope diario es el
// que acota las operaciones de escritura de R2 (ver el presupuesto en images.ts).

export const IMAGE_REQUESTS_PER_HOUR = 15;
export const IMAGE_REQUESTS_PER_DAY = 40;

const TABLE = "image_upload_requests";
const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

// Duck-typed para que los tests puedan pasar un doble sin red.
export interface RateLimitDb {
  from(table: string): {
    select(columns: string, opts?: { count?: "exact"; head?: boolean }): {
      eq(column: string, value: string): {
        gt(column: string, value: string): PromiseLike<{ count: number | null; error: unknown }>;
      };
    };
    insert(row: Record<string, unknown>): PromiseLike<{ error: unknown }>;
  };
}

/** Falla abierto: un problema de la tabla no debe bloquear a todo el mundo. */
export async function isWithinLimit(db: RateLimitDb, userId: string): Promise<boolean> {
  const [hour, day] = await Promise.all([countSince(db, userId, HOUR_MS), countSince(db, userId, DAY_MS)]);
  return hour < IMAGE_REQUESTS_PER_HOUR && day < IMAGE_REQUESTS_PER_DAY;
}

async function countSince(db: RateLimitDb, userId: string, windowMs: number): Promise<number> {
  const since = new Date(Date.now() - windowMs).toISOString();
  const { count, error } = await db
    .from(TABLE)
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .gt("requested_at", since);
  return error ? 0 : (count ?? 0);
}

export async function recordRequest(db: RateLimitDb, userId: string): Promise<void> {
  try {
    await db.from(TABLE).insert({ user_id: userId });
  } catch {
    // No crítico: peor caso, esta petición no cuenta.
  }
}
