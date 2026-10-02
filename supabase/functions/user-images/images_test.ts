import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";

import {
  buildObjectKey,
  fitsUserQuota,
  GC_GRACE_MS,
  MAX_BYTES_PER_USER,
  MAX_OBJECTS_PER_USER,
  isImageAction,
  isJpeg,
  keyFromUrl,
  ParamsError,
  parseListObjectsXml,
  parseUploadParams,
  publicUrlFor,
  selectKeysToDelete,
  userPrefix,
} from "./images.ts";

const USER = "8a1f7c3e-2b4d-4e6f-9a0b-1c2d3e4f5a6b";
const PLAYLIST = "11111111-2222-4333-8444-555555555555";
const BASE = "https://pub-abc.r2.dev";

Deno.test("isImageAction solo acepta las tres acciones", () => {
  assertEquals(isImageAction("upload"), true);
  assertEquals(isImageAction("gc"), true);
  assertEquals(isImageAction("delete_all"), true);
  assertEquals(isImageAction("delete"), false);
  assertEquals(isImageAction(null), false);
});

Deno.test("parseUploadParams exige un uuid para portadas y lo ignora para avatar", () => {
  assertEquals(parseUploadParams(new URLSearchParams({ kind: "avatar" })), { kind: "avatar", playlistId: null });
  assertEquals(
    parseUploadParams(new URLSearchParams({ kind: "playlist", playlist_id: PLAYLIST.toUpperCase() })),
    { kind: "playlist", playlistId: PLAYLIST },
  );
  assertThrows(() => parseUploadParams(new URLSearchParams({ kind: "playlist" })), ParamsError);
  assertThrows(
    () => parseUploadParams(new URLSearchParams({ kind: "playlist", playlist_id: "../../otro" })),
    ParamsError,
  );
  assertThrows(() => parseUploadParams(new URLSearchParams({ kind: "banner" })), ParamsError);
});

Deno.test("isJpeg mira la firma, no la extensión", () => {
  assertEquals(isJpeg(new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00])), true);
  assertEquals(isJpeg(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d])), false);
  assertEquals(isJpeg(new Uint8Array([0xff, 0xd8])), false);
});

Deno.test("las claves cuelgan del prefijo del usuario", () => {
  const cover = buildObjectKey(USER, { kind: "playlist", playlistId: PLAYLIST }, "abc");
  const avatar = buildObjectKey(USER, { kind: "avatar", playlistId: null }, "def");
  assertEquals(cover, `u/${USER}/p/${PLAYLIST}/abc.jpg`);
  assertEquals(avatar, `u/${USER}/a/def.jpg`);
  assertEquals(cover.startsWith(userPrefix(USER)), true);
  assertEquals(avatar.startsWith(userPrefix(USER)), true);
});

Deno.test("keyFromUrl es la inversa de publicUrlFor, con cualquier dominio", () => {
  const key = `u/${USER}/a/def.jpg`;
  assertEquals(keyFromUrl(publicUrlFor(`${BASE}/`, key)), key);
  assertEquals(keyFromUrl(`${BASE}/${key}?v=2`), key);
  // Cambiar de r2.dev a un dominio propio no deja huérfanas las URLs viejas.
  assertEquals(keyFromUrl(`https://img.ejemplo.com/${key}`), key);
  // Una portada de Deezer no apunta a nada del usuario.
  assertEquals(keyFromUrl("https://e-cdns-images.dzcdn.net/images/cover.jpg")?.startsWith(userPrefix(USER)), false);
  assertEquals(keyFromUrl("gradient:3"), null);
  assertEquals(keyFromUrl("C:\\docs\\a.jpg"), null);
  assertEquals(keyFromUrl(null), null);
});

Deno.test("parseListObjectsXml lee claves, fechas y paginación", () => {
  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult>
  <IsTruncated>true</IsTruncated>
  <Contents><Key>u/x/a/1.jpg</Key><LastModified>2026-09-29T10:00:00.000Z</LastModified><Size>98304</Size></Contents>
  <Contents><Key>u/x/p/y/2.jpg</Key><LastModified>2026-09-29T11:00:00.000Z</LastModified></Contents>
  <NextContinuationToken>tok&amp;en</NextContinuationToken>
</ListBucketResult>`;
  const page = parseListObjectsXml(xml);
  assertEquals(page.objects.map((o) => o.key), ["u/x/a/1.jpg", "u/x/p/y/2.jpg"]);
  assertEquals(page.objects[0].lastModified, Date.parse("2026-09-29T10:00:00.000Z"));
  assertEquals(page.objects[0].size, 98304);
  assertEquals(page.objects[1].size, 0);
  assertEquals(page.nextToken, "tok&en");

  const last = parseListObjectsXml("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>");
  assertEquals(last, { objects: [], nextToken: null });
});

Deno.test("selectKeysToDelete respeta lo referenciado y el periodo de gracia", () => {
  const now = Date.parse("2026-09-29T12:00:00Z");
  const old = now - GC_GRACE_MS - 1;
  const objects = [
    { key: "u/x/p/a/actual.jpg", lastModified: old, size: 1 },
    { key: "u/x/p/a/vieja.jpg", lastModified: old, size: 1 },
    { key: "u/x/p/borrada/1.jpg", lastModified: old, size: 1 },
    { key: "u/x/a/recien.jpg", lastModified: now - 1000, size: 1 },
  ];
  const referenced = new Set(["u/x/p/a/actual.jpg"]);
  assertEquals(selectKeysToDelete(objects, referenced, now), ["u/x/p/a/vieja.jpg", "u/x/p/borrada/1.jpg"]);
});

Deno.test("fitsUserQuota limita por cantidad y por bytes", () => {
  const obj = (size: number) => ({ key: "k", lastModified: 0, size });
  assertEquals(fitsUserQuota([], 150_000), true);
  assertEquals(fitsUserQuota([obj(MAX_BYTES_PER_USER - 150_000)], 150_000), true);
  assertEquals(fitsUserQuota([obj(MAX_BYTES_PER_USER - 150_000)], 150_001), false);
  assertEquals(fitsUserQuota(Array.from({ length: MAX_OBJECTS_PER_USER }, () => obj(1)), 1), false);
});
