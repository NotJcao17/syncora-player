// Rate limit de operaciones por usuario. Mismo diseño que el de `ai-assistant`
// (registro de eventos con ventana deslizante; ver migraciones 8 y 19): sin
// permiso de DELETE, nadie puede resetear su propio cupo.
//
// Es un tope diario y no por hora porque lo único que protege es el
// presupuesto mensual de escrituras de R2 (ver images.ts). Un tope por hora
// solo estorbaba a quien configura muchas playlists de una sentada.

/** Subidas + limpiezas al día. Cada una cuesta como mucho 2 escrituras (LIST + PUT). */
export const IMAGE_REQUESTS_PER_DAY = 50;

/**
 * Margen extra solo para `delete_all` (eliminar la cuenta): que haber agotado
 * el cupo del día no deje las imágenes en el bucket, pero sin que llamarlo en
 * bucle sea gratis (cada llamada es un LIST).
 */
export const DELETE_ALL_EXTRA_PER_DAY = 5;

const TABLE = "image_upload_requests";
const DAY_MS = 24 * 60 * 60 * 1000;

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
export async function isWithinLimit(db: RateLimitDb, userId: string, extra = 0): Promise<boolean> {
  const since = new Date(Date.now() - DAY_MS).toISOString();
  const { count, error } = await db
    .from(TABLE)
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .gt("requested_at", since);
  if (error) return true;
  return (count ?? 0) < IMAGE_REQUESTS_PER_DAY + extra;
}

export async function recordRequest(db: RateLimitDb, userId: string): Promise<void> {
  try {
    await db.from(TABLE).insert({ user_id: userId });
  } catch {
    // No crítico: peor caso, esta petición no cuenta.
  }
}
