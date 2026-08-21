// Fase 7.E.2/7.E.3 -- rate limit por usuario para la llave compartida de
// Gemini. Ver la migración `20250001000008_ai_rate_limits.sql` para el
// diseño de la tabla (registro de eventos, ventana deslizante de 1 hora).
//
// Límite elegido: 20 llamadas/hora por usuario. Justificación (Documento
// Maestro §4.1 + plan_fase_7.md): con ~1.000 RPD compartidos entre todos los
// usuarios y un uso real estimado de ~3 peticiones/usuario/día activo de IA,
// 20/hora es "generoso" en el sentido que pide el Documento Maestro (no
// castiga un uso intenso y legítimo en una sesión corta) mientras sigue
// acotando a cualquier usuario individual o bot a como mucho 480/día -- muy
// por debajo del RPD total, así que ningún usuario solo puede agotar la
// cuota compartida del día por su cuenta salvo que lo intente muchas horas
// seguidas (y para eso está el otro código de error, `shared_quota_exhausted`,
// que cubre precisamente cuando la cuota diaria SÍ se agota).
export const SHARED_KEY_HOURLY_LIMIT = 20;

const TABLE = "ai_rate_limit_requests";
const WINDOW_MS = 60 * 60 * 1000;

// Duck-typed a propósito (en vez de importar el tipo `SupabaseClient` de
// supabase-js) para que `rate_limit_test.ts` pueda pasar un doble de prueba
// sin depender de la resolución de red del paquete remoto.
//
// A propósito NO tiene un método `delete`: la primera versión de este módulo
// podaba filas viejas con el JWT del usuario, lo cual requería darle al
// usuario permiso RLS de DELETE sobre su propia fila -- pero esa misma
// política le daba a CUALQUIER cliente autenticado la posibilidad de borrar
// su propio historial de peticiones directamente (sin pasar por esta
// función) y resetear su cupo a voluntad, dejando el rate limit opcional
// (hallazgo de seguridad del review de 7.E). Ni el cliente ni la Edge
// Function deben poder borrar filas de esta tabla con el JWT del usuario --
// ver la migración para el detalle y el plan de poda futuro (cron de
// servidor, fuera de este módulo).
export interface RateLimitDb {
  from(table: string): {
    select(columns: string, opts?: { count?: "exact"; head?: boolean }): {
      eq(column: string, value: string): {
        gt(column: string, value: string): Promise<{ count: number | null; error: unknown }>;
      };
    };
    insert(row: Record<string, unknown>): Promise<{ error: unknown }>;
  };
}

export interface RateLimitResult {
  allowed: boolean;
  count: number;
}

/**
 * Cuenta cuántas peticiones aceptadas tiene el usuario en la última hora.
 * No inserta nada -- eso lo hace `recordRequest` por separado, para que el
 * caller pueda decidir primero (`allowed`) antes de comprometerse a
 * registrar el intento.
 */
export async function checkRateLimit(db: RateLimitDb, userId: string): Promise<RateLimitResult> {
  const windowStart = new Date(Date.now() - WINDOW_MS).toISOString();
  const { count, error } = await db
    .from(TABLE)
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .gt("requested_at", windowStart);

  if (error) {
    // Si no se puede consultar el límite, se falla ABIERTO (se permite la
    // petición) en vez de bloquear a todo el mundo por un problema
    // transitorio de la tabla de rate limit -- el límite es una protección
    // contra abuso, no una garantía dura de cuota exacta.
    return { allowed: true, count: 0 };
  }

  const currentCount = count ?? 0;
  return { allowed: currentCount < SHARED_KEY_HOURLY_LIMIT, count: currentCount };
}

/**
 * Registra la petición actual (una fila nueva). NO poda filas viejas -- ver
 * el comentario de `RateLimitDb` arriba y la migración para el porqué: la
 * poda se quitó del camino del usuario/función por completo tras el review
 * de seguridad de 7.E, ya que compartía la misma política RLS que permitía
 * a cualquier cliente resetear su propio rate limit. La corrección del
 * límite no depende de la poda -- `checkRateLimit` siempre filtra por
 * `requested_at > windowStart`, así que filas viejas sin borrar no afectan
 * el conteo, solo el tamaño de la tabla con el tiempo (poda futura: cron de
 * servidor, fuera del alcance de este módulo).
 *
 * Un fallo al insertar no se propaga -- peor caso, ese request en particular
 * no cuenta para el límite, lo cual es preferible a bloquear la función de
 * IA por un problema transitorio de la tabla de rate limit.
 */
export async function recordRequest(db: RateLimitDb, userId: string): Promise<void> {
  try {
    await db.from(TABLE).insert({ user_id: userId });
  } catch {
    // No crítico, ver doc de arriba.
  }
}
