// Sirve las imágenes del bucket `syncora-images` (docs/fases/portadas_y_fotos.md).
//
// Existe para acotar las lecturas de R2: el subdominio público r2.dev no
// permite ningún límite propio, mientras que el plan gratuito de Workers corta
// en 100 000 peticiones al día sin cobrar el exceso. Como cada petición lee R2
// como mucho una vez, el peor caso es ~3 M de lecturas al mes, dentro de los
// 10 M gratuitos. Con r2.dev desactivado, este Worker es la única vía pública.
//
// Solo lectura: subir y borrar sigue siendo cosa de la Edge Function.
import { imageKeyFromPath } from "./keys.ts";

// Tipos mínimos del binding de R2, para no depender de @cloudflare/workers-types.
interface R2ObjectBody {
  body: ReadableStream;
  httpEtag: string;
  size: number;
}
interface R2Bucket {
  get(key: string): Promise<R2ObjectBody | null>;
}
interface Env {
  BUCKET: R2Bucket;
}

const notFound = () => new Response("Not found", { status: 404 });

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }

    const key = imageKeyFromPath(new URL(request.url).pathname);
    if (!key) return notFound();

    const object = await env.BUCKET.get(key);
    if (!object) return notFound();

    const headers = new Headers({
      "Content-Type": "image/jpeg",
      "Content-Length": String(object.size),
      // Cada subida tiene un nombre nuevo: el contenido de una URL nunca
      // cambia y la app puede guardarla en caché para siempre.
      "Cache-Control": "public, max-age=31536000, immutable",
      ETag: object.httpEtag,
    });
    if (request.headers.get("If-None-Match") === object.httpEtag) {
      return new Response(null, { status: 304, headers });
    }
    return new Response(request.method === "HEAD" ? null : object.body, { headers });
  },
};
