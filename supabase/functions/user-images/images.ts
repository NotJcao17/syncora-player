// Lógica pura de la Edge Function `user-images` (docs/fases/portadas_y_fotos.md).
// Sin red ni Supabase: todo lo que se puede equivocar en silencio (qué se
// borra, qué se acepta) vive aquí para poder testearlo con `deno test`.

/** Tope de bytes de una imagen ya procesada por el cliente (640 px, JPEG 85 ≈ 60-150 KB). */
export const MAX_IMAGE_BYTES = 1_500_000;

/** Imágenes que un usuario puede tener guardadas a la vez, tras la limpieza. */
export const MAX_OBJECTS_PER_USER = 300;

/**
 * Antigüedad mínima para que la limpieza borre un objeto que nadie
 * referencia. Cubre la carrera entre subir la imagen y que el cliente guarde
 * su URL en la fila, y dos dispositivos subiendo a la vez.
 */
export const GC_GRACE_MS = 10 * 60 * 1000;

export type ImageAction = "upload" | "gc" | "delete_all";
export type ImageKind = "playlist" | "avatar";

export function isImageAction(value: unknown): value is ImageAction {
  return value === "upload" || value === "gc" || value === "delete_all";
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_RE.test(value);
}

export class ParamsError extends Error {}

export interface UploadParams {
  kind: ImageKind;
  playlistId: string | null;
}

/** Valida `kind` y `playlist_id` de la query de una subida. */
export function parseUploadParams(params: URLSearchParams): UploadParams {
  const kind = params.get("kind");
  if (kind === "avatar") return { kind, playlistId: null };
  if (kind !== "playlist") throw new ParamsError("'kind' debe ser 'playlist' o 'avatar'");
  const playlistId = params.get("playlist_id");
  if (!isUuid(playlistId)) throw new ParamsError("'playlist_id' no es un id válido");
  return { kind, playlistId: playlistId.toLowerCase() };
}

/** JPEG por firma real, no por el `Content-Type` que diga el cliente. */
export function isJpeg(bytes: Uint8Array): boolean {
  return bytes.length > 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
}

/** Todo lo de un usuario cuelga de este prefijo: borrar la cuenta es borrarlo entero. */
export function userPrefix(userId: string): string {
  return `u/${userId.toLowerCase()}/`;
}

/**
 * Nombre nuevo en cada subida: una URL que nunca cambia de contenido deja que
 * cualquier caché la guarde para siempre sin mostrar nunca la imagen vieja.
 */
export function buildObjectKey(userId: string, params: UploadParams, random: string): string {
  const base = userPrefix(userId);
  return params.kind === "avatar" ? `${base}a/${random}.jpg` : `${base}p/${params.playlistId}/${random}.jpg`;
}

export function publicUrlFor(publicBaseUrl: string, key: string): string {
  return `${publicBaseUrl.replace(/\/+$/, "")}/${key}`;
}

/** Inversa de [publicUrlFor]; `null` si la URL no es de este bucket. */
export function keyFromUrl(publicBaseUrl: string, url: string | null | undefined): string | null {
  if (!url) return null;
  const base = `${publicBaseUrl.replace(/\/+$/, "")}/`;
  if (!url.startsWith(base)) return null;
  const key = url.slice(base.length).split(/[?#]/)[0];
  return key.length > 0 ? key : null;
}

export interface StoredObject {
  key: string;
  lastModified: number;
}

export interface ListPage {
  objects: StoredObject[];
  nextToken: string | null;
}

/** Respuesta XML de `ListObjectsV2` (S3/R2). Las claves que genera esta función no llevan caracteres a escapar. */
export function parseListObjectsXml(xml: string): ListPage {
  const objects: StoredObject[] = [];
  for (const match of xml.matchAll(/<Contents>([\s\S]*?)<\/Contents>/g)) {
    const body = match[1];
    const key = /<Key>([\s\S]*?)<\/Key>/.exec(body)?.[1];
    if (!key) continue;
    const modified = /<LastModified>([\s\S]*?)<\/LastModified>/.exec(body)?.[1];
    const parsed = modified ? Date.parse(modified) : NaN;
    // Sin fecha legible se trata como recién subido: nunca se borra por error.
    objects.push({ key: decodeXml(key), lastModified: Number.isNaN(parsed) ? Date.now() : parsed });
  }
  const truncated = /<IsTruncated>true<\/IsTruncated>/.test(xml);
  const token = /<NextContinuationToken>([\s\S]*?)<\/NextContinuationToken>/.exec(xml)?.[1];
  return { objects, nextToken: truncated && token ? decodeXml(token) : null };
}

function decodeXml(value: string): string {
  return value
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&apos;", "'")
    .replaceAll("&amp;", "&");
}

/**
 * Qué borrar en una pasada de limpieza: los objetos que ninguna fila del
 * usuario referencia y que ya pasaron el periodo de gracia.
 */
export function selectKeysToDelete(
  objects: StoredObject[],
  referencedKeys: Set<string>,
  now: number,
  graceMs: number = GC_GRACE_MS,
): string[] {
  return objects
    .filter((o) => !referencedKeys.has(o.key) && now - o.lastModified >= graceMs)
    .map((o) => o.key);
}
