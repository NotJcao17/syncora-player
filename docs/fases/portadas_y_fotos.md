# Portadas propias de playlists y foto de perfil

Sesión del 2026-09-29. Subir una imagen propia como portada de una playlist creada por el usuario y
como foto de perfil. En modo local todo se queda en el dispositivo; con cuenta, las imágenes viven en
**Cloudflare R2** (10 GB gratis) y se sincronizan como cualquier otro dato de la playlist.

## Estado actual verificado (leyendo código)

- `playlists.cover_url` ya admite cuatro formas: vacío (cuadrícula 2x2 automática), `gradient:N`,
  `color:#hex` y URL. `PlaylistCoverWidget` además ya pinta rutas de archivo local
  (`/…`, `C:\…`, `file://…`), aunque nada de la app las generaba.
- `CoverPalette.of` solo reconocía rutas locales que empiezan con `/` o `file://`: una ruta de
  Windows (`C:\…`) la trataba como URL y fallaba en silencio.
- El avatar es una semilla de DiceBear (`profiles.avatar_seed` con cuenta; `LocalModeStorage` sin
  cuenta) y se pintaba copiando el mismo `SvgPicture.network` en cuatro sitios.
- `migrateLocalPlaylistsToAccount` no subía la portada de la playlist (ni degradado ni color): al
  crear la cuenta se perdía.
- `image` 4.x y `file_picker` ya estaban en el árbol de dependencias: no entra ningún plugin nativo.

## Decisiones

- **La Edge Function (`user-images`) es la única que habla con R2.** Las llaves de R2 son secretos
  de Supabase y nunca llegan a la app. La función recibe el JPEG ya procesado, valida sesión,
  propiedad de la playlist, tamaño y formato, y lo sube. **No escribe en la base de datos**: devuelve
  la URL pública y el cliente actualiza `cover_url`/`avatar_url` con su propio JWT, igual que las
  funciones de IA.
- **El cliente siempre re-codifica**: recorte cuadrado centrado, 640 px (portada) o 320 px (avatar),
  JPEG calidad 85, sin EXIF (se descartan GPS, modelo de cámara, etc.). Una portada queda en ~60-150 KB.
  La función solo acepta JPEG de hasta 1,5 MB.
- **Nombre de objeto único por subida** (`u/{uid}/p/{playlistId}/{aleatorio}.jpg`,
  `u/{uid}/a/{aleatorio}.jpg`): así ninguna caché de imágenes muestra la portada anterior.
- **Limpieza por recolección, no por borrado puntual.** En cada subida (y tras quitar una portada o
  borrar una playlist) la función lista los objetos del usuario y borra los que ya no referencia
  ninguna fila suya (`playlists.cover_url`, `profiles.avatar_url`). Los objetos de menos de 10 min
  se respetan: cubre la carrera entre subir y guardar la URL, y dos dispositivos a la vez. Si un
  borrado falla, la siguiente pasada lo recoge.
- **Límites contra abuso** (R2 exige tarjeta registrada aunque se use gratis): 30 subidas/hora por
  usuario (misma tabla de eventos que la IA) y 300 imágenes como máximo por usuario.
- **Eliminar la cuenta borra antes todas sus imágenes** de R2 (best-effort: si R2 falla, la cuenta
  se borra igual).
- **Editar la portada con cuenta requiere internet** (regla Online-First de siempre); en modo local
  la imagen se copia a `Documents/syncora/custom_images/`.
- **La foto de perfil tiene prioridad sobre la semilla**: elegir un avatar de DiceBear quita la foto.
- **Al crear la cuenta desde modo local**, las portadas propias (y ahora también degradados y colores)
  se suben con la playlist; la foto de perfil local también.

## Bundles

1. **Servidor:** migración 19 (`profiles.avatar_url`, tabla de rate limit de imágenes) y Edge
   Function `user-images` (`upload`, `gc`, `delete_all`) con tests de Deno de la lógica pura.
2. **Cliente, núcleo:** `CustomImageService` (elegir, procesar en isolate, guardar local, subir,
   limpiar) + helper de rutas locales, arreglo de `CoverPalette` en Windows.
3. **Portadas:** opción "Subir imagen" en el diálogo de editar playlist, limpieza al borrar,
   migración local → cuenta.
4. **Foto de perfil:** widget `UserAvatar` único, subir/quitar foto en el selector, borrado de
   imágenes al eliminar la cuenta.
5. **Aviso de privacidad y documentación**, incluida la guía de configuración de R2.
