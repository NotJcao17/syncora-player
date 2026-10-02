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
  La función solo acepta JPEG de hasta 512 KB (la app nunca pasa de ~300 KB).
- **Nombre de objeto único por subida** (`u/{uid}/p/{playlistId}/{aleatorio}.jpg`,
  `u/{uid}/a/{aleatorio}.jpg`): así ninguna caché de imágenes muestra la portada anterior.
- **Limpieza por recolección, no por borrado puntual.** En cada subida (y tras quitar una portada o
  borrar una playlist) la función lista los objetos del usuario y borra los que ya no referencia
  ninguna fila suya (`playlists.cover_url`, `profiles.avatar_url`). Los objetos de menos de 10 min
  se respetan: cubre la carrera entre subir y guardar la URL, y dos dispositivos a la vez. Si un
  borrado falla, la siguiente pasada lo recoge.
- **Límites que garantizan no salir del plan gratuito** (R2 exige tarjeta y no tiene tope de gasto
  propio), calculados para el peor caso: 250 cuentas agotándolos a propósito con un cliente
  modificado. Por usuario: **30 MB y 300 imágenes guardadas** a la vez, y **500 operaciones cada
  31 días** (subidas + limpiezas; misma tabla de eventos que la IA), más 10 de margen solo para
  `delete_all` para que eliminar la cuenta no falle por haber agotado el cupo. El cupo es mensual y
  no diario ni por hora (decisión del usuario): lo que protege es un presupuesto mensual, y el uso
  real se concentra en pocos días, al configurar la biblioteca. La ventana es de 31 días deslizantes
  porque el periodo de facturación de Cloudflare no coincide con el mes natural. Resultado: como
  mucho 250 × 30 MB = **7,5 GB** de los 10 GB, y 250 × 510 × 2 = **255 000** escrituras de 1 millón
  (cada subida es un LIST + un PUT; borrar es gratis en R2). También acota las invocaciones de la
  Edge Function (500 000/mes compartidas con la IA): 250 × 510 = 127 500 en el peor caso. Si se sube
  el tope de cuentas, hay que bajar `MAX_BYTES_PER_USER` y el cupo en proporción. Cambiar una imagen por otra
  gasta **una** operación: la anterior la recoge la siguiente subida, sin pedir una limpieza aparte.
- **Las lecturas pasan por un Worker de Cloudflare** (`cloudflare/image-worker/`), no por `r2.dev`,
  que se deja desactivado. `r2.dev` no admite límites propios y una URL pedida en bucle gastaría
  lecturas (10 M/mes gratis) sin tope. El plan gratuito de Workers corta en 100 000 peticiones al
  día **sin cobrar el exceso**, y cada petición lee R2 como mucho una vez: peor caso ~3 M de lecturas
  al mes. El Worker rechaza sin tocar el bucket cualquier ruta que no tenga el formato exacto de
  nuestras claves. Costo de esta garantía: bajo un ataque, las imágenes nuevas dejan de cargar hasta
  las 00:00 UTC (las ya vistas siguen en la caché de la app). El tope es de toda la cuenta de
  Cloudflare: otros Workers que se creen lo comparten. Alternativa evaluada: dominio propio con
  caché y regla de límite por IP (no da tope duro y cuesta el dominio).
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

## Qué quedó implementado

| Pieza | Dónde |
| :--- | :--- |
| Migración 19 (`profiles.avatar_url`, `image_upload_requests`) | `supabase/migrations/20250001000019_user_images.sql` |
| Edge Function (`upload`, `gc`, `delete_all`) + tests de Deno | `supabase/functions/user-images/` |
| Elegir, procesar, guardar y subir imágenes | `lib/core/images/custom_image_service.dart` |
| Diálogo de editar playlist (extraído, con "Subir imagen") | `lib/features/library/widgets/edit_playlist_dialog.dart` |
| Liberar la imagen al cambiar portada o borrar la playlist | `lib/features/library/services/playlist_cover_service.dart` |
| Avatar único (`avatarInfoProvider`, `UserAvatar`) | `lib/features/profile/widgets/user_avatar.dart` |
| Subir / quitar foto de perfil | `lib/features/profile/widgets/avatar_selector_sheet.dart` |
| Migración local → cuenta de portadas y foto | `playlist_import_export_service.dart`, `auth_screen.dart` |
| Borrado de imágenes al eliminar la cuenta | `delete_account_flow.dart` |
| Aviso de privacidad | `legal_screen.dart` |

Compatibilidad: si la migración 19 o la función todavía no están desplegadas, lo único que falla es
subir una imagen con cuenta (mensaje de error, nada se guarda a medias). Elegir una semilla de
DiceBear solo manda `avatar_url` cuando había foto, así que sigue funcionando sin la migración.

## Límites conocidos

- La imagen se recorta al centro, sin editor de recorte: meter uno exige un plugin nativo que en
  Windows no existe (`image_cropper` usa UCrop/TOCropViewController).
- Si la subida sale bien pero guardar la URL en `playlists` falla, la imagen queda huérfana hasta la
  siguiente limpieza del usuario (la recoge sola).
- Si R2 falla justo al eliminar una cuenta, sus imágenes quedan en el bucket sin dueño. Con URLs
  imposibles de adivinar no son accesibles en la práctica; se pueden borrar a mano por el prefijo
  `u/{uid}/` desde el panel de Cloudflare.
- `playlists.cover_url` sigue aceptando cualquier texto, como antes: un cliente modificado podría
  poner una URL externa en una playlist pública. No es nuevo de esta sesión.

## Guía: configurar Cloudflare R2 (una sola vez)

R2 es el almacenamiento de archivos de Cloudflare, compatible con la API de S3 de Amazon. El plan
gratuito incluye **10 GB de almacenamiento**, **1 millón de escrituras** y **10 millones de lecturas
al mes**, y **la descarga de imágenes no se cobra nunca** (a diferencia de Supabase Storage, que
tiene 1 GB y 5 GB/mes de egress). Con portadas de ~100 KB, 10 GB son unas 100 000 imágenes.

1. **Crear la cuenta y activar R2.** En <https://dash.cloudflare.com> → *R2 Object Storage* →
   *Purchase R2 / Activate*. Cloudflare pide una tarjeta (o PayPal) aunque no se pase del plan
   gratuito: solo cobra lo que exceda los límites de arriba. Recomendado: en *Manage Account →
   Billing → Notifications* crear un aviso de uso para enterarte si algo se dispara.
2. **Crear el bucket.** *R2 → Create bucket* → nombre `syncora-images`, ubicación automática,
   clase *Standard*. No hace falta configurar CORS: la app es nativa, no un navegador.
3. **Publicar las lecturas con el Worker** (no con `r2.dev`, ver "Decisiones"). Desde
   `cloudflare/image-worker/`: `npx wrangler login` (abre el navegador para autorizar) y
   `npx wrangler deploy`. La primera vez puede pedir elegir un subdominio `workers.dev` para la
   cuenta. Al terminar imprime la URL, `https://syncora-images.<subdominio>.workers.dev`: ese es
   `R2_PUBLIC_BASE_URL` (sin `/` al final). En el bucket, *Settings → Public Development URL* debe
   quedar **desactivado**. Si algún día hay dominio propio, se le puede asignar al Worker y solo
   cambia el secreto: la limpieza reconoce los objetos por su ruta, no por el dominio.
4. **Crear las llaves de API.** Menú izquierdo *R2 Object Storage* (la lista de buckets, no el
   bucket) → panel *Account Details* a la derecha → junto a *API Tokens*, botón **Manage** →
   **Create Account API token** → nombre `syncora-user-images`, permiso **Object Read & Write**,
   *Specify bucket(s)*: **Apply to specific buckets only** → `syncora-images`, *TTL*: **Forever**, sin
   filtro de IP → *Create Account API Token*. La pantalla siguiente muestra **una sola vez** el
   *Access Key ID* y el *Secret Access Key* (el "Token value" no hace falta). El **Account ID** es la
   parte entre `https://` y `.r2.cloudflarestorage.com` de la *S3 API* que se ve en *Settings →
   General* del bucket.
5. **Guardar los secretos en Supabase** (desde la raíz del repo; nunca en `.env` ni en Git):

   ```bash
   supabase secrets set R2_ACCOUNT_ID=... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... R2_BUCKET=syncora-images R2_PUBLIC_BASE_URL=https://syncora-images.<subdominio>.workers.dev
   ```

6. **Aplicar la migración y desplegar la función:**

   ```bash
   supabase db push
   supabase functions deploy user-images
   ```

7. **Probar:** con cuenta, cambia la portada de una playlist por una imagen. En el panel de R2
   (bucket → *Objects*) debe aparecer `u/<tu-uid>/p/<id-playlist>/<algo>.jpg`. Si la app dice "El
   almacenamiento de imágenes no está configurado", falta algún secreto; si dice "No se pudo guardar
   la imagen", las llaves no tienen permiso sobre el bucket (revisa el paso 4). Los logs están en
   Supabase → *Edge Functions → user-images → Logs*.

## Estado de cierre (2026-10-01)

Fase cerrada. R2, el Worker (`syncora-images.*.workers.dev`, con `r2.dev` desactivado), la
migración 19 y la función `user-images` están desplegados y probados por el usuario: las portadas
con cuenta suben, se sincronizan y se sirven por el Worker. Ajustes hechos durante las pruebas:

- Cupo de operaciones: de 30/hora a 15/hora + 40/día, a 50/día y finalmente a **500 cada 31 días**.
- `delete_all` no tenía ningún límite (cada llamada es un LIST): ahora tiene su margen propio.
- Cambiar una imagen por otra ya no pide una limpieza aparte: gasta una operación, no dos.
- Álbum retirado por Deezer: `/album/{id}` responde 200 con `{"error": {"code": 800}}`, y se
  mostraba como "Álbum Sin Título" con el error técnico de la portada. `DeezerApi.getAlbum` lanza
  ahora `DeezerNotFoundException` y la pantalla dice que el álbum ya no está disponible; el relleno
  de géneros cachea esos álbumes como sin género para no volver a preguntar.

Observaciones abiertas, sin causa encontrada en el código:

- En PC, tras cambiar en el móvil una portada de imagen a degradado, al recargar Biblioteca se vio
  unos segundos la cuadrícula automática antes del degradado. El sync escribe la portada en un solo
  paso; puede ser un efecto de ese cambio puntual. Revisar solo si se repite con playlists nuevas.
- Un "Syncora Player no responde" al abrir la build de desarrollo que queda en el teléfono tras
  `flutter run`, que no se repitió. Probable lentitud de la build debug; confirmar con `--release`.
