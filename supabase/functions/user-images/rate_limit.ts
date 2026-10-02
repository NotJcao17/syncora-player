// Rate limit de operaciones por usuario. Mismo diseño que el de `ai-assistant`
// (registro de eventos con ventana deslizante; ver migraciones 8 y 19): sin
// permiso de DELETE, nadie puede resetear su propio cupo.
//
// El cupo es mensual porque lo que protege es el presupuesto mensual de
// escrituras de R2 (ver images.ts), y porque el uso real se concentra en pocos
// días (al configurar la biblioteca): un tope diario u horario solo estorbaba.
// La ventana es de 31 días deslizantes: así ningún periodo de facturación de
// Cloudflare (que no coincide con el mes natural) puede acumular más del cupo.

/** Subidas + limpiezas en 31 días. Cada una cuesta como mucho 2 escrituras (LIST + PUT). */
export const IMAGE_REQUESTS_PER_WINDOW = 500;

/**
 * Margen extra solo para `delete_all` (eliminar la cuenta): que haber agotado
 * el cupo no deje las imágenes en el bucket, pero sin que llamarlo en bucle
 * sea gratis (cada llamada es un LIST).
 */
export const DELETE_ALL_EXTRA = 10;

const TABLE = "image_upload_requests";
const WINDOW_MS = 31 * 24 * 60 * 60 * 1000;

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
  const since = new Date(Date.now() - WINDOW_MS).toISOString();
  const { count, error } = await db
    .from(TABLE)
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .gt("requested_at", since);
  if (error) return true;
  return (count ?? 0) < IMAGE_REQUESTS_PER_WINDOW + extra;
}

export async function recordRequest(db: RateLimitDb, userId: string): Promise<void> {
  try {
    await db.from(TABLE).insert({ user_id: userId });
  } catch {
    // No crítico: peor caso, esta petición no cuenta.
  }
}
