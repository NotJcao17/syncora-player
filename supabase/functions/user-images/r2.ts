// Acceso a Cloudflare R2 por su API compatible con S3. Las llaves son
// secretos de la función (`supabase secrets set`), nunca viajan a la app.
import { AwsClient } from "https://esm.sh/aws4fetch@1.0.20";

import { parseListObjectsXml, type StoredObject } from "./images.ts";

export interface R2Config {
  accountId: string;
  accessKeyId: string;
  secretAccessKey: string;
  bucket: string;
  publicBaseUrl: string;
}

/** `null` si falta algún secreto. */
export function readR2Config(): R2Config | null {
  const accountId = Deno.env.get("R2_ACCOUNT_ID");
  const accessKeyId = Deno.env.get("R2_ACCESS_KEY_ID");
  const secretAccessKey = Deno.env.get("R2_SECRET_ACCESS_KEY");
  const bucket = Deno.env.get("R2_BUCKET");
  const publicBaseUrl = Deno.env.get("R2_PUBLIC_BASE_URL");
  if (!accountId || !accessKeyId || !secretAccessKey || !bucket || !publicBaseUrl) return null;
  return { accountId, accessKeyId, secretAccessKey, bucket, publicBaseUrl };
}

export interface ObjectStore {
  put(key: string, bytes: Uint8Array<ArrayBuffer>): Promise<void>;
  delete(key: string): Promise<void>;
  list(prefix: string): Promise<StoredObject[]>;
}

export class StorageError extends Error {}

export function createR2Store(config: R2Config): ObjectStore {
  const client = new AwsClient({
    accessKeyId: config.accessKeyId,
    secretAccessKey: config.secretAccessKey,
    service: "s3",
    region: "auto",
  });
  const base = `https://${config.accountId}.r2.cloudflarestorage.com/${config.bucket}`;

  return {
    async put(key, bytes) {
      const res = await client.fetch(`${base}/${key}`, {
        method: "PUT",
        body: bytes,
        headers: {
          "Content-Type": "image/jpeg",
          // Cada subida tiene nombre propio, así que el contenido de una URL
          // nunca cambia: se puede cachear para siempre.
          "Cache-Control": "public, max-age=31536000, immutable",
        },
      });
      if (!res.ok) throw new StorageError(`R2 PUT ${res.status}`);
      await res.body?.cancel();
    },

    async delete(key) {
      const res = await client.fetch(`${base}/${key}`, { method: "DELETE" });
      await res.body?.cancel();
      if (!res.ok && res.status !== 404) throw new StorageError(`R2 DELETE ${res.status}`);
    },

    async list(prefix) {
      const all: StoredObject[] = [];
      let token: string | null = null;
      do {
        const url = new URL(base);
        url.searchParams.set("list-type", "2");
        url.searchParams.set("prefix", prefix);
        if (token) url.searchParams.set("continuation-token", token);
        const res = await client.fetch(url.toString(), { method: "GET" });
        if (!res.ok) {
          await res.body?.cancel();
          throw new StorageError(`R2 LIST ${res.status}`);
        }
        const page = parseListObjectsXml(await res.text());
        all.push(...page.objects);
        token = page.nextToken;
      } while (token);
      return all;
    },
  };
}
