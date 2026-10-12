-- Ronda 8 (H-R8-12): reparar el orden de las canciones en la nube.
--
-- Hasta la versión 1.0.2, solo la importación mandaba `order_index`. Todo lo
-- demás ("Agregar a playlist", "Me gusta", guardar una colección, subir una
-- playlist local) quedaba con el DEFAULT 0, y quien bajaba la playlist (otro
-- dispositivo, o el mismo tras cerrar e iniciar sesión) veía esas canciones al
-- principio, desempatadas por un uuid aleatorio.
--
-- En Syncora no existe reordenar a mano: el orden de una playlist es el orden
-- en que se agregaron sus canciones. Aquí se reconstruye así:
--   1. `added_at`: cada inserción posterior tiene una fecha mayor.
--   2. `order_index`: dentro de un mismo bloque de la importación (misma
--      fecha), el que mandó la app.
--   3. `ctid`: dentro de un mismo INSERT sin `order_index` (guardar una
--      colección), el orden físico, que normalmente es el de la lista enviada.
--
-- Solo toca las playlists que tienen `order_index` repetidos o nulos: las que
-- ya están bien no cambian. Las copias locales de cada dispositivo no se
-- reordenan solas (el sync no reordena); se ve en la siguiente descarga
-- completa.

WITH broken AS (
  SELECT playlist_id
  FROM public.playlist_tracks
  GROUP BY playlist_id
  HAVING COUNT(*) <> COUNT(DISTINCT order_index)
),
ranked AS (
  SELECT
    pt.id,
    (ROW_NUMBER() OVER (
      PARTITION BY pt.playlist_id
      ORDER BY pt.added_at, pt.order_index NULLS LAST, pt.ctid
    ) - 1)::INTEGER AS new_index
  FROM public.playlist_tracks pt
  JOIN broken b ON b.playlist_id = pt.playlist_id
)
UPDATE public.playlist_tracks pt
SET order_index = r.new_index
FROM ranked r
WHERE pt.id = r.id
  AND pt.order_index IS DISTINCT FROM r.new_index;
