# Preparación del lanzamiento 1.0 (2026-10-09)

Leer antes de tocar **compartir playlists**, `followed_playlists`, el enlace de la web, los deep
links `syncoraplayer://playlist/...`, el aviso legal o la firma del APK.

## Web y Google

- La web (`syncora-web`, Astro en Cloudflare Pages) vive en **https://syncoraplayer.app**. Tiene
  `/privacidad/` (aviso de privacidad LFPDPPP, responsable Juan Carlos Orozco), `/terminos/`
  (términos + descargo de contenido) y `/playlist/<id>` (vista de solo lectura de una playlist
  compartida). Correo `contacto@syncoraplayer.app` por Email Routing de Cloudflare (solo recibe).
- Pantalla de consentimiento de Google: marca **verificada y publicada** (nombre "Syncora Player",
  logo, dominio verificado en Search Console) y la app en **producción**. El logo de 120 px está en
  `docs/branding/google-oauth-logo-120.png`.
- Supabase → Authentication → URL Configuration: Site URL `https://syncoraplayer.app`.

## Compartir playlists

### Antes (lo que estaba roto)

- "Copiar enlace" apuntaba a `syncora.netlify.app` (nunca existió) y copiaba el enlace aunque la
  playlist fuera privada: la web no podía leerla.
- "Hacer pública" era una opción aparte; canciones y álbumes también tenían "Copiar enlace" sin
  ninguna vista en la web.
- **Agujero de RLS (H-L1):** la política `playlist_tracks_owner` solo exigía `auth.uid() = user_id`.
  Con el id de una playlist ajena (que los enlaces hacen público) cualquiera con sesión podía
  insertarle canciones por la API REST, y el dueño no podía quitarlas porque el DELETE también
  filtraba por `user_id`. Corregido en la migración 24.

### Ahora

| Acción | Qué hace |
|---|---|
| **Compartir enlace** (playlist propia, con cuenta) | Si es privada, pide confirmación, la publica (nube primero) y copia `https://syncoraplayer.app/playlist/<remoteId>` |
| **Dejar de compartir** | La vuelve privada: el enlace deja de funcionar y quien la guardó la pierde en su siguiente sync |
| Abrir el enlace | La web muestra la playlist; "Abrir en la app" usa `intent://` (Android) o `syncoraplayer://playlist/<id>` (Windows) |
| **Guardar** (con cuenta) | Fila en `followed_playlists`; la playlist aparece en Biblioteca como **solo lectura** (`Playlists.isFollowed`) y el sync la mantiene igual a la original |
| **Guardar** (sin cuenta) | Copia editable (`sourceRef = shared_playlist:<id>`), porque guardar de verdad necesita la nube |
| **Guardar una copia** (desde una guardada) | Copia editable propia |
| **Quitar de tu biblioteca** | Borra la fila de `followed_playlists` y la copia local |

"Tus me gusta", "On Repeat" y las playlists del modo local no se comparten (`canSharePlaylist`).
Solo se comparten playlists: se quitaron "Copiar enlace" de canciones y álbumes, y el intent-filter
de Android ya solo declara `playlist`.

### Reglas que no conviene revertir

- **Una guardada es de solo lectura en todas partes**: `canEditPlaylistManually`,
  `canAddTracksToPlaylist` y `FolderService.canBeFoldered` la excluyen. Fijarla es local (no toca la
  fila del dueño, `togglePlaylistPin`).
- **El sync de las propias ignora las guardadas** (`_syncPlaylistsAndTracks` filtra `isFollowed`):
  si no, las podaba por no estar entre las del usuario o las adoptaba por título.
- **`syncPlaylistDetail` de una guardada va por `pullFollowedPlaylist`**: el camino normal la
  tomaba por borrada al abrirla.
- **Si la lista de guardadas no se pudo leer completa, no se poda nada.**
- Las escrituras de guardadas pasan por `_withFollowedLock`: el sync y el botón "Guardar" pueden
  coincidir y crearían dos copias.
- A diferencia de las propias, una guardada **respeta el orden de la original**: si cambia, se
  reemplaza la lista entera (`replaceTracks`).
- **IA**: el selector "basado en una playlist mía" excluye las guardadas (D-11: el texto de otro
  usuario no entra al contexto de una IA que actúa con tus permisos).
- El enlace pendiente vive en `pendingSharedPlaylist` y lo abre `AppShell`: así espera al login y
  funciona aunque la app arranque en frío desde el enlace.

### Windows

El instalador registra el esquema `syncoraplayer://` en `HKCU\Software\Classes` (se borra al
desinstalar). Si la app ya está abierta, `windows/runner/main.cpp` reenvía el enlace por
`WM_COPYDATA` a `app_links`. Un build de `flutter run` no registra el esquema: probar con el
instalado.

### Fallos de la primera prueba en dispositivo (2026-10-09)

- **Android: "no routes for location: syncoraplayer://playlist/..."**. Con el deep linking de
  Flutter activo (por defecto), Android le pasaba el enlace crudo a GoRouter además de a
  `app_links`. El manifiesto lo desactiva (`flutter_deeplinking_enabled = false`) y el `redirect`
  manda a Inicio cualquier `syncoraplayer://` que llegue de todos modos.
- **Windows con la app ya abierta no navegaba**: `main.cpp` reenviaba el enlace con `dwData = 0`, y
  `app_links` solo acepta `APPLINK_MSG_ID` (`WM_USER + 2`); lo ignoraba sin error.
- **Windows: abrir un enlace con la app maximizada la dejaba en tamaño normal.** `main.cpp` hacía
  `ShowWindow(SW_SHOW)` sobre la ventana existente. Ahora solo la restaura si está minimizada (a
  maximizada si lo estaba, `WPF_RESTORETOMAXIMIZED`) y si no, solo la trae al frente. Verificado
  con un script que maximiza/minimiza la ventana y lanza una segunda instancia con el enlace.
- **Guardar una copia y compartirla a la vez desordenaba las canciones**: compartir sin `remoteId`
  disparaba un `syncLibrary`, que encontraba la remota recién creada y vacía, adoptaba la local por
  el título y le podaba las pistas que aún no subían. Ahora `saveTracksAsPlaylist` y
  `createPlaylistWithMatchedTracks` bloquean la remota con `SyncLocks` mientras se llenan (como la
  importación), y compartir ya no dispara un sync.

## Aviso legal

`legal_screen.dart`: descargo de contenido (Syncora no aloja ni distribuye; uso personal y no
comercial; responsabilidad del usuario), qué implica compartir, y enlaces a la versión completa en
la web. Se quitó la línea que decía que Gemini busca la letra en Google (desde la ronda 7 es
YouTube Music). La atribución a Deezer y LRCLib ya estaba en Créditos y ahora también en el pie de
la web.

## Firma del APK

Hasta ahora el release se firmaba con la llave de **debug**, que solo existe en la PC donde se
compila: perderla obligaba a todos a desinstalar (y perder descargas) para actualizar.

- Llave nueva: `android/app/syncora-release.jks` (alias `syncora`, RSA 4096, 10 000 días) y
  `android/key.properties`. Ninguno va a git.
- `build.gradle.kts` firma con ella y **falla** si falta `key.properties` en un build de release, en
  vez de volver a la de debug.
- SHA-256 del certificado (para App Links si algún día se agregan):
  `EF:11:7A:58:60:83:B2:CB:4D:26:8C:E8:7D:60:6E:15:27:9D:28:01:EC:5A:87:41:75:E1:F7:6C:02:E1:A2:19`
- Un APK firmado con la llave nueva no se instala encima de uno de `flutter run` o de un release
  anterior firmado con la de debug: hay que desinstalar primero (una sola vez).

## Pasos manuales

- [ ] Aplicar la migración 24 (`supabase db push`).
- [ ] Respaldar `android/app/syncora-release.jks` y `android/key.properties` fuera del repo.

## Pruebas en dispositivo

- [ ] Compartir una playlist privada: pide confirmación, el enlace abre la web con la playlist.
- [ ] "Dejar de compartir": la web dice "no disponible".
- [ ] Desde la web en Android: "Abrir en la app" abre la playlist; "Guardar" la deja en Biblioteca con
      "Guardada", sin opciones de edición; cambios del dueño llegan al refrescar.
- [ ] Lo mismo en Windows con la app cerrada y con la app abierta.
- [ ] Sin cuenta: abrir un enlace y guardar crea una copia editable.
- [ ] "Guardar una copia" y "Quitar de tu biblioteca" desde una guardada.
