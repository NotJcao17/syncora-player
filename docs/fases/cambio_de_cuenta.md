# Cambio de cuenta: datos locales de la cuenta anterior

Leer antes de tocar el cierre de sesión, el inicio de sesión, el modo sin cuenta o
`lib/features/auth/services/account_data_owner.dart`.

## El bug (2026-10-05)

Al cerrar sesión y entrar con otra cuenta, Inicio ("Porque escuchaste a…", "Novedades
de tus artistas"), "On Repeat" y la canción en curso seguían siendo de la cuenta
anterior. Las playlists sí desaparecían porque el sync poda las que tienen `remoteId`.

Dos causas, una por plataforma:

1. **Cerrar sesión solo cerraba la sesión de Supabase.** El historial, On Repeat (solo
   local, el sync nunca la poda), las carpetas, la sesión del reproductor y las
   búsquedas recientes se quedaban en el dispositivo. `flutter clean` no ayuda: la base
   vive en `Documentos`, no en `build/`.
2. **Android restauraba la copia de seguridad al reinstalar.** El manifiesto no
   desactivaba la copia automática de Google; desinstalar y reinstalar devolvía la base
   y la sesión viejas. Verificado: `adb shell dumpsys backup` listaba
   `com.syncora.syncora_player` entre las restauraciones.

No hubo fuga a la nube: la cuenta nueva tenía 0 escuchas (las filas viejas ya estaban
marcadas como subidas).

## El arreglo

**Dueño de los datos locales** (`account.local_data_owner` en `shared_preferences`): el
id de la cuenta, o `local` en modo sin cuenta.

| Momento | Qué pasa |
|---|---|
| Cerrar sesión (Configuración o menú de PC) | Para el reproductor, sube el historial pendiente (máx. 8 s), cierra sesión y borra lo local. **El dueño se conserva**: si un sync en vuelo escribe algo después, se limpia cuando entre otra cuenta. |
| Entrar con **otra** cuenta | Borra lo local **antes** del sync y de navegar (al revés, el sync podría insertar las playlists nuevas y el borrado llevárselas). |
| Entrar con **la misma** cuenta | No borra nada: la app sigue sirviendo sin conexión. |
| "Usar sin cuenta" con datos de una cuenta | Los borra. |
| Arranque con sesión de otra cuenta (p. ej. login con Google que abre la app en frío por deep link) | `main.dart` borra antes de `runApp`, sin reproductor ni providers vivos. |
| Sin dueño anotado (instalaciones anteriores) | Se adopta sin borrar: no hay forma de saber de quién son. |
| Modo local → cuenta (`auth_screen.dart`) | Sin cambios: migra o descarta como antes y después anota la cuenta como dueña. Si la app se cerró a mitad de esa migración, el arranque adopta lo que quedó en vez de borrarlo. |

Qué se borra (`wipeAccountDataAtRest` + `AccountDataGuard.wipeNow`): playlists y sus
pistas ("Tus me gusta" queda vacía), **carpetas** (antes `wipeLocalLibrary` no las
tocaba, tampoco al eliminar la cuenta), álbumes guardados, historial, imágenes propias,
foto del modo local, búsquedas recientes y la cola del reproductor
(`resetForAccountChange`). **Las descargas no**: son del dispositivo.

Android: `allowBackup="false"` y `data_extraction_rules.xml`, que excluye todo de la
copia en la nube y de la transferencia entre teléfonos (en Android 12+ esa
transferencia no respeta `allowBackup`). Reinstalar ahora es empezar de cero: la
biblioteca vuelve con el sync, las descargas no.

## Portada de On Repeat en "Escuchado recientemente"

`RecentlyPlayedItem` pasaba `isLiked` pero no `isGenerated`, así que On Repeat salía con
la cuadrícula de 4 portadas en vez del degradado con el ícono de repetir que usa en la
barra lateral y en Biblioteca.

## Verificado

- `test/features/auth/account_data_owner_test.dart`: la regla del dueño y el borrado
  (incluido que las descargas sobreviven).
- Windows release: con el dueño apuntando a la cuenta vieja, el arranque borró On Repeat,
  "Porque escuchaste a Charli xcx" y la canción en curso, y dejó solo las playlists de la
  cuenta nueva.

## Datos fuera de Documentos en Windows (2026-10-06)

Hasta aquí la app guardaba la base (`syncora_local.sqlite`), `api_cache`, `repair_state.json` y
`syncora/` (portadas, descargas, importaciones, imágenes propias) en la carpeta **Documentos** del
usuario. Se veía como basura suelta y la compartían el build de desarrollo y el instalado (parte
de por qué se colaron datos de una cuenta a otra en el PC).

Ahora todo sale de `appDataDirectory()` (`lib/core/storage/app_storage.dart`):

- **Windows:** `%LOCALAPPDATA%\com.syncora\Syncora Player`. Local y no Roaming porque las
  descargas pesan. Limpiar `%temp%` no lo toca (es `AppData\Local\Temp`, otra carpeta).
- **Android:** sin cambios, la carpeta de documentos de la app (ya es privada).

Al primer arranque en Windows, `migrateWindowsDataOutOfDocuments()` (en `main.dart`, antes de que
nada abra la base) mueve lo que encuentre en Documentos sin pisar nada que ya exista, y reescribe
las rutas **absolutas** guardadas: descargas y sus portadas y portadas propias en la base, los JSON
de `syncora/` (índice de portadas, importaciones) y la foto del modo local. Deja el marcador
`.migrated-from-documents` para no repetirlo. Verificado en el PC de desarrollo: Documentos quedó
limpio y la app abrió con la biblioteca, On Repeat y la sesión intactas.

Lo que ya vivía en `getApplicationSupportDirectory` (Roaming: sesión del reproductor, motor,
ajustes) no se movió.

## Cuenta eliminada desde otro dispositivo (2026-10-08, ronda 7)

**Antes:** al eliminar la cuenta en el PC, el celular seguía con sesión hasta que vencía su token de
acceso (1 h por defecto: la API solo comprueba la firma). En ese tiempo la nube le respondía "no
tienes nada" (RLS sobre un usuario que ya no existe), el sync vaciaba sus playlists y álbumes sin
avisar y cada escritura fallaba. Al vencer el token, la renovación se rechazaba y Supabase cerraba
la sesión sin ninguna explicación (verificado en gotrue 2.27.2: `_doRefresh` emite `signedOut`
con `SignOutReason.sessionExpired`).

**Ahora** (`lib/features/auth/services/remote_account_check.dart`):

- Antes de cada sync que baja o poda (`syncLibrary`, `syncPlaylistDetail`, `syncSavedAlbums`,
  `syncListeningHistory`) y al volver a la app, `auth.getUser()`. Como mucho una petición de Auth
  cada 5 minutos por cuenta; si el token venció, se renueva antes.
- **Solo** 403 + `user_not_found` cuenta como eliminada (es lo que devuelve el servidor de Auth,
  `maybeLoadUserOrSession`, que busca el usuario antes que la sesión). Entonces: se cancela el
  sync, se para el reproductor, se cierra la sesión (local) y se borra lo local como al eliminarla
  aquí (las descargas se quedan). El dueño anotado sigue siendo la cuenta borrada.
- 403 + `session_not_found` (sesión cerrada en el servidor): solo se cierra la sesión; los datos
  se quedan con su dueño, como con una sesión vencida.
- **Todo lo demás** (sin red, 5xx, token vencido, error sin código) es "no se sabe": el sync sigue
  como siempre y no se borra nada.
- **Si la sesión desaparece o cambia de cuenta mientras se comprueba, el sync no corre**
  (hallazgo P1 de la revisión independiente): sin sesión, los repositorios devuelven listas vacías
  y el sync podaba la biblioteca. Pasaba de forma determinista con una cuenta eliminada y el token
  vencido, porque la propia comprobación dispara la renovación que cierra la sesión.
- No actúa si la sesión ya es de otra cuenta, ni mientras este dispositivo elimina su propia
  cuenta (`AccountDataGuard.deletingAccountHere`, entre la RPC y el cierre de sesión).
- La pantalla de inicio explica por qué se cerró la sesión (`pendingAuthNotice`): "Tu cuenta se
  eliminó desde otro dispositivo…" o, si Supabase la cerró solo, "Tu sesión se cerró. Vuelve a
  iniciar sesión." Cerrar sesión a mano no muestra nada. El aviso caduca a los 10 minutos, para
  no aparecer días después si el usuario siguió sin cuenta.

**Cuando Supabase cierra la sesión solo** (migración 23, `account_exists`). Es el caso **común**,
no el raro: en Android `supabase_flutter` deja de renovar el token en cuanto la app pasa a segundo
plano, así que si el celular no usó la app en la última hora el token está vencido y la renovación
(rechazada, porque los tokens se borraron con la cuenta) cierra la sesión antes de poder preguntar
a `/user`. Ese error es el mismo que el de una sesión cerrada en el servidor, así que no sirve para
distinguir. Entonces `serverSignOutWatcherProvider` (creado en `SyncoraApp`; el stream de gotrue es
un `ReplaySubject` y también entrega el cierre del arranque) llama a
`AccountDataGuard.handleSessionEndedByServer`, que pregunta a la RPC `account_exists` (sin sesión,
llave anon) por el dueño de los datos locales:

- `false` → borra lo local (las descargas no) y avisa "Tu cuenta se eliminó desde otro
  dispositivo…".
- `true`, sin red o cualquier duda → solo el aviso genérico; no se borra nada.
- Si mientras se pregunta alguien entra o cambia el dueño, no toca nada (ya lo hizo `claimFor`).

La RPC solo responde sí/no para un UUID concreto (122 bits aleatorios: no se puede adivinar ni
enumerar) y no devuelve ningún dato de la cuenta. Verificada en vivo sin sesión: `false` para un
UUID inexistente y error de tipo para una entrada que no es UUID.

**Un token vencido no afecta al usuario** (verificado en `supabase` 2.16.1 / gotrue 2.27.2): cada
petición a Supabase renueva el token antes de salir si venció (`_getAccessToken` →
`getSession()`), también en segundo plano; el token de renovación no caduca (salvo límites de
sesión, que son del plan Pro y no están activos). La reproducción no depende de Supabase (audio de
YouTube, metadatos de Deezer): el único efecto de un fallo de red ahí es que el historial o un "Me
gusta" se suben más tarde. Solo se vuelve a pedir inicio de sesión si el token de renovación deja
de existir: cuenta eliminada o sesión cerrada en el servidor.
