// Rate limit de subidas por usuario. Mismo diseño que el de `ai-assistant`
// (registro de eventos, ventana deslizante de 1 hora; ver migraciones 8 y 19):
// sin permiso de DELETE, nadie puede resetear su propio cupo.

export const IMAGE_REQUESTS_PER_HOUR = 30;

const TABLE = "image_upload_requests";
const WINDOW_MS = 60 * 60 * 1000;

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
  const since = new Date(Date.now() - WINDOW_MS).toISOString();
  const { count, error } = await db
    .from(TABLE)
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .gt("requested_at", since);
  if (error) return true;
  return (count ?? 0) < IMAGE_REQUESTS_PER_HOUR;
}

export async function recordRequest(db: RateLimitDb, userId: string): Promise<void> {
  try {
    await db.from(TABLE).insert({ user_id: userId });
  } catch {
    // No crítico: peor caso, esta petición no cuenta.
  }
}
