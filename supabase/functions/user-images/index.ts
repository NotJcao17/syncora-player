// Portadas propias de playlists y foto de perfil (docs/fases/portadas_y_fotos.md).
//
// Única pieza que habla con Cloudflare R2. Reglas:
//   1. Las llaves de R2 son secretos de la función; la app nunca las ve.
//   2. El cliente de Supabase se crea con el JWT del usuario, nunca con
//      SERVICE_ROLE_KEY: la propiedad de la playlist y las URLs referenciadas
//      se leen con los permisos RLS del propio usuario.
//   3. No escribe datos de usuario: devuelve la URL y el cliente la guarda en
//      `playlists.cover_url` / `profiles.avatar_url` con su propio JWT. La
//      única tabla que toca es su rate limit.
//   4. Nunca borra un objeto que alguna fila del usuario referencia, ni uno
//      subido hace menos de GC_GRACE_MS.
//
// Acciones (query `?action=`):
//   upload      body = JPEG; `kind=playlist&playlist_id=<uuid>` o `kind=avatar`.
//   gc          borra las imágenes del usuario que ya nada referencia.
//   delete_all  borra todas sus imágenes (antes de eliminar la cuenta).
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

import {
  buildObjectKey,
  isImageAction,
  isJpeg,
  keyFromUrl,
  fitsUserQuota,
  MAX_IMAGE_BYTES,
  ParamsError,
  parseUploadParams,
  publicUrlFor,
  selectKeysToDelete,
  type StoredObject,
  userPrefix,
} from "./images.ts";
import { createR2Store, type ObjectStore, type R2Config, readR2Config, StorageError } from "./r2.ts";
import { DELETE_ALL_EXTRA_PER_DAY, isWithinLimit, type RateLimitDb, recordRequest } from "./rate_limit.ts";

type ErrorCode =
  | "invalid_request"
  | "unauthorized"
  | "not_found"
  | "too_large"
  | "unsupported_format"
  | "rate_limited_user"
  | "quota_exceeded"
  | "storage_error"
  | "server_misconfigured"
  | "internal_error";

const STATUS: Record<ErrorCode, number> = {
  invalid_request: 400,
  unauthorized: 401,
  not_found: 404,
  too_large: 413,
  unsupported_format: 415,
  rate_limited_user: 429,
  quota_exceeded: 409,
  storage_error: 502,
  server_misconfigured: 500,
  internal_error: 500,
};

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function fail(code: ErrorCode, message: string): Response {
  return json({ error: code, message }, STATUS[code]);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return fail("invalid_request", "Método no soportado, usa POST");
  try {
    return await handle(req);
  } catch (error) {
    if (error instanceof StorageError) {
      console.error("user-images: R2", error.message);
      return fail("storage_error", "No se pudo guardar la imagen. Intenta de nuevo más tarde.");
    }
    console.error("user-images: error no anticipado", error instanceof Error ? error.message : error);
    return fail("internal_error", "Ocurrió un error inesperado. Intenta de nuevo.");
  }
});

async function handle(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const action = url.searchParams.get("action");
  if (!isImageAction(action)) {
    return fail("invalid_request", "'action' debe ser upload, gc o delete_all");
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return fail("unauthorized", "Falta el header Authorization");

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const r2 = readR2Config();
  if (!supabaseUrl || !supabaseAnonKey || !r2) {
    return fail("server_misconfigured", "El almacenamiento de imágenes no está configurado");
  }

  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) return fail("unauthorized", "Sesión inválida o expirada");

  const store = createR2Store(r2);
  const rateDb = supabase as unknown as RateLimitDb;

  if (action === "delete_all") {
    // Margen propio sobre el cupo diario: eliminar la cuenta no debe fallar
    // por haber cambiado muchas portadas ese día, pero tampoco puede quedar
    // sin tope (cada llamada es un LIST, que R2 cobra).
    if (!(await isWithinLimit(rateDb, user.id, DELETE_ALL_EXTRA_PER_DAY))) {
      return fail("rate_limited_user", "Demasiadas peticiones hoy. Intenta de nuevo mañana.");
    }
    await recordRequest(rateDb, user.id);
    const objects = await store.list(userPrefix(user.id));
    for (const o of objects) await store.delete(o.key);
    return json({ deleted: objects.length });
  }

  if (!(await isWithinLimit(rateDb, user.id))) {
    return fail("rate_limited_user", "Llegaste al límite de cambios de imagen de hoy. Intenta de nuevo mañana.");
  }

  if (action === "gc") {
    const { deleted } = await collectGarbage(store, supabase, user.id, r2);
    await recordRequest(rateDb, user.id);
    return json({ deleted });
  }

  return await upload(req, url, store, supabase, rateDb, user.id, r2);
}

async function upload(
  req: Request,
  url: URL,
  store: ObjectStore,
  supabase: SupabaseClient,
  rateDb: RateLimitDb,
  userId: string,
  r2: R2Config,
): Promise<Response> {
  let params;
  try {
    params = parseUploadParams(url.searchParams);
  } catch (error) {
    if (error instanceof ParamsError) return fail("invalid_request", error.message);
    throw error;
  }

  if (params.kind === "playlist") {
    // `playlists_public_read` deja leer playlists públicas ajenas, así que el
    // filtro por dueño es explícito. "Tus me gusta" tiene portada fija.
    const { data, error } = await supabase
      .from("playlists")
      .select("id, is_liked")
      .eq("id", params.playlistId)
      .eq("user_id", userId)
      .maybeSingle();
    if (error || !data || data.is_liked === true) {
      return fail("not_found", "La playlist no existe o no es tuya");
    }
  }

  const declared = Number(req.headers.get("Content-Length") ?? "0");
  if (declared > MAX_IMAGE_BYTES) return fail("too_large", "La imagen es demasiado grande");
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (bytes.length > MAX_IMAGE_BYTES) return fail("too_large", "La imagen es demasiado grande");
  if (!isJpeg(bytes)) return fail("unsupported_format", "Formato de imagen no admitido");

  const { remaining } = await collectGarbage(store, supabase, userId, r2);
  if (!fitsUserQuota(remaining, bytes.length)) {
    return fail("quota_exceeded", "Llegaste al máximo de imágenes guardadas en tu cuenta.");
  }

  const key = buildObjectKey(userId, params, crypto.randomUUID().replaceAll("-", ""));
  await store.put(key, bytes);
  await recordRequest(rateDb, userId);
  return json({ url: publicUrlFor(r2.publicBaseUrl, key) });
}

/**
 * Borra las imágenes del usuario que ya ninguna fila suya referencia. Si no
 * se puede saber qué está referenciado, no borra nada.
 */
async function collectGarbage(
  store: ObjectStore,
  supabase: SupabaseClient,
  userId: string,
  r2: R2Config,
): Promise<{ deleted: number; remaining: StoredObject[] }> {
  const objects = await store.list(userPrefix(userId));
  if (objects.length === 0) return { deleted: 0, remaining: [] };

  const [covers, profile] = await Promise.all([
    supabase.from("playlists").select("cover_url").eq("user_id", userId).not("cover_url", "is", null),
    supabase.from("profiles").select("avatar_url").eq("id", userId).maybeSingle(),
  ]);
  if (covers.error || profile.error) return { deleted: 0, remaining: objects };

  const referenced = new Set<string>();
  for (const row of covers.data ?? []) {
    const key = keyFromUrl(row.cover_url as string | null);
    if (key) referenced.add(key);
  }
  const avatarKey = keyFromUrl(profile.data?.avatar_url as string | null | undefined);
  if (avatarKey) referenced.add(avatarKey);

  const toDelete = selectKeysToDelete(objects, referenced, Date.now());
  const gone = new Set<string>();
  for (const key of toDelete) {
    try {
      await store.delete(key);
      gone.add(key);
    } catch {
      // Lo recoge la siguiente pasada.
    }
  }
  return { deleted: gone.size, remaining: objects.filter((o) => !gone.has(o.key)) };
}
