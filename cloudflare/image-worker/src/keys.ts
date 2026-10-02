// Formato exacto de las claves que genera la Edge Function `user-images`
// (supabase/functions/user-images/images.ts, buildObjectKey):
//   u/{uid}/a/{32 hex}.jpg              foto de perfil
//   u/{uid}/p/{playlistId}/{32 hex}.jpg portada de playlist
// Cualquier otra ruta se rechaza sin tocar el bucket, así que inventar rutas
// no gasta lecturas de R2.
const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const KEY_RE = new RegExp(`^u/${UUID}/(a|p/${UUID})/[0-9a-f]{32}\\.jpg$`);

/** Clave del objeto para [pathname] (`/u/...`), o `null` si no es una imagen nuestra. */
export function imageKeyFromPath(pathname: string): string | null {
  const key = pathname.replace(/^\/+/, "");
  return KEY_RE.test(key) ? key : null;
}
