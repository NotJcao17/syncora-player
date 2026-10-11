# Lanzar una versión nueva de la app

Leer **solo cuando se pida lanzar una versión**. Los commits y pushes del día a día no tienen
nada que ver con esto: una versión es una foto de `master` que se compila y se publica en GitHub
Releases para que la gente la descargue.

## Cómo funciona

- La web (`syncora-web`) enlaza a `releases/latest/download/Syncora.apk` y
  `releases/latest/download/SyncoraSetup.exe`. GitHub siempre redirige al archivo de la **última
  versión publicada**, así que la web no se toca al lanzar, mientras los archivos se llamen así.
  La versión, el tamaño y la fecha que muestra la web los lee sola de la API de GitHub.
- "Última versión" = el release más reciente que **no** es pre-release. El canal del motor de
  extracción (`engine-channel`) es pre-release a propósito y no interfiere. **Nunca marcar un
  release de la app como pre-release**: los botones de la web dejarían de encontrarlo.
- Requisitos que publica la web: Android 7.0 o superior (`minSdk` 24) y Windows 10 u 11 de 64 bits.

## Llave de firma de Android

El APK se firma con `android/app/syncora-release.jks` usando las contraseñas de
`android/key.properties`. **Ninguno de los dos está en git** y sin ellos no se puede publicar una
versión que se instale encima de las anteriores: Android rechaza un APK firmado con otra llave, y
la única salida para el usuario sería desinstalar y perder sus descargas.

- Hay respaldo de los dos archivos fuera del repo. En una PC nueva se copian a esas mismas rutas.
- Si falta `key.properties`, el build de release falla a propósito (no vuelve a la llave de debug).

## Número de versión

Vive en una sola línea de `pubspec.yaml`: `version: 1.2.3+7`.

| Parte | Cuándo sube | Ejemplo |
|---|---|---|
| `1` (mayor) | Cambio grande: rediseño completo, algo que rompe compatibilidad con versiones anteriores (datos, cuenta) | `1.4.2` → `2.0.0` |
| `2` (menor) | Funciones nuevas | `1.4.2` → `1.5.0` |
| `3` (parche) | Solo correcciones | `1.4.2` → `1.4.3` |
| `+7` (build) | **Siempre**, de uno en uno. Android rechaza instalar encima un APK con un número igual o menor | `+7` → `+8` |

Al subir la mayor se reinician la menor y el parche a 0; al subir la menor se reinicia el parche.
El build nunca se reinicia.

El instalador de Windows lee la versión de esta misma línea (`installer/build_release.ps1` se la
pasa a Inno Setup), así que no se escribe en ningún otro lado. Configuración también la muestra
sola: la lee del binario con `package_info_plus` (`appVersionProvider` en `settings_screen.dart`).
**Nunca escribir el número a mano en la app**: hasta la 1.0.1 estaba fijo en Configuración y esa
versión siguió diciendo "v1.0.0".

## Pasos

1. **Subir la versión** en `pubspec.yaml` (ver tabla) y comitear: `chore: version 1.2.3`.
2. **Push** a `master`. El release etiqueta el último commit de GitHub, así que todo lo que deba
   ir en la versión tiene que estar subido antes.
3. **Compilar** desde la raíz del repo (tarda unos minutos; no correr otro `flutter build` a la vez):
   ```bash
   powershell -ExecutionPolicy Bypass -File installer/build_release.ps1
   ```
   Deja `build/release/Syncora.apk` y `build/release/SyncoraSetup.exe`. Con `-SkipAndroid` o
   `-SkipWindows` compila solo uno.
4. **Probar** los dos archivos: instalar el APK en el teléfono y correr el instalador en Windows.
5. **Publicar** (el script imprime este comando con la versión ya puesta):
   ```bash
   gh release create v1.2.3 build/release/Syncora.apk build/release/SyncoraSetup.exe --title "Syncora 1.2.3" --generate-notes
   ```
   Crea la etiqueta `v1.2.3` sobre el último commit de `master`, sube los dos archivos y arma las
   notas con los commits desde la versión anterior. También se puede hacer en GitHub → Releases →
   "Draft a new release": misma etiqueta, arrastrar los dos archivos, "Set as latest" marcado y
   "pre-release" sin marcar.
6. **Verificar**: en la web, el botón descarga la versión nueva y el texto muestra el número
   nuevo (la web guarda en caché la respuesta de GitHub 30 minutos por pestaña).
7. **Versión de respaldo de la web**: en `syncora-web`, poner el número nuevo en
   `FALLBACK_VERSION` de `src/data/site.ts`, comitear y hacer push (Cloudflare la publica sola). Solo
   se muestra si la consulta a la API de GitHub falla, pero no debe quedarse atrás.

El badge de versión del README (`img.shields.io/github/v/release/...`) y el de descargas se
actualizan solos; no se tocan. Si GitHub sigue mostrando la versión anterior, es la caché de
imágenes de GitHub (camo), que se refresca sola en unas horas.

## Si algo sale mal

- **Se publicó con un error:** no borrar el release a la ligera (la gente ya pudo descargarlo).
  Corregir, subir el parche (`1.2.3` → `1.2.4`, build +1) y lanzar otra versión.
- **El script falla en Inno Setup:** revisar que exista `C:\Program Files (x86)\Inno Setup 6\ISCC.exe`.
  Las DLL de Visual C++ las copia el script desde `System32`; no ponerlas en `syncora.iss` con esa
  ruta (Inno Setup es de 32 bits y Windows le daría las de 32 bits).
- **`AppId` de `installer/syncora.iss`:** no cambiarlo nunca. Es lo que hace que la versión nueva
  se instale encima de la anterior.
