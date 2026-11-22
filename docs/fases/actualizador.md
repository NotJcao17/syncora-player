# Actualizador de la app (2026-11-22)

Desde la 1.4.0 la app avisa de versiones nuevas y se actualiza sola, con los mismos archivos que
descarga la web (`releases/latest` de GitHub). **Quien tenga la 1.3.0 o anterior tiene que bajar
la versión nueva a mano una última vez**: el actualizador solo existe a partir de la versión que
lo trae.

## Cómo funciona

- **Consulta** (`lib/core/updates/`): `GET api.github.com/repos/NotJcao17/syncora-player/releases/latest`
  y se compara la etiqueta (`v1.4.0`) con la versión del binario (`package_info_plus`). Ese
  endpoint nunca devuelve borradores ni pre-releases, así que el canal del motor
  (`engine-channel`) no se confunde con una versión. Sin el archivo de la plataforma
  (`Syncora.apk` / `SyncoraSetup.exe`) no se avisa.
- **Al abrir la app** (`AppShell._checkForAppUpdate`, solo en release, 8 s después de arrancar):
  como mucho una consulta cada 12 h (`updates.last_check_ms`; la API sin cuenta permite 60 por
  hora por IP). Un fallo no cuenta como consulta y no muestra nada. "Omitir esta versión"
  (`updates.skipped_version`) calla solo esa versión al abrir la app.
- **Configuración → Buscar actualizaciones**: consulta siempre y ofrece también la versión
  omitida.
- **Descarga**: va a la caché (Android: `cache/updates`; Windows: `%TEMP%\SyncoraUpdate`),
  comprueba tamaño y el SHA-256 que GitHub publica en cada archivo (`digest`) y borra lo de
  versiones anteriores. Si el archivo ya estaba bajado y verificado, no se vuelve a bajar (pasa al
  volver de dar el permiso de instalar en Android). Cerrar la hoja cancela la descarga.
- **Instalación en Android** (`UpdateInstaller` en `packages/syncora_android`): `ACTION_VIEW` al
  instalador del sistema, con el APK servido por `UpdateFileProvider` (privado, solo lectura,
  solo `cache/updates/*.apk`, con el permiso temporal del intent). Se usa el instalador del
  sistema y no una sesión de `PackageInstaller` porque así Android maneja solo el permiso de
  "instalar apps desconocidas" la primera vez y al terminar ofrece "Abrir". El manifiesto del
  plugin declara `REQUEST_INSTALL_PACKAGES`: sin él el instalador rechaza el APK. Android solo lo
  instala encima si va firmado con la misma llave, y nunca sin que el usuario confirme (sin Play
  Store no se puede).
- **Instalación en Windows**: el instalador corre con
  `/SILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /RELAUNCH=1` y la app se cierra
  (`windowManager.close()`, como el botón X). `installer/syncora.iss` vuelve a abrir la app al
  terminar solo con `/RELAUNCH=1`; instalando a mano sigue igual que antes. El instalador no pide
  administrador (instalación por usuario). Un archivo bajado por la app no lleva la marca de
  "descargado de internet", así que SmartScreen no lo frena.

## Al lanzar una versión

Nada cambia en `docs/lanzar_version.md`, salvo una recomendación: lo que se escriba a mano en las
notas del release (`gh release create ... --notes "..." --generate-notes`) es lo que la app
muestra como novedades. Lo que agrega `--generate-notes` (el enlace de "Full Changelog" y la
lista de PRs) se quita; si no queda nada, la app dice "Trae correcciones y mejoras." y enlaza a la
página del release. **No renombrar los archivos del release**: la web y la app los buscan por
nombre.

## Pruebas

- `test/core/updates/app_update_test.dart`: versiones, lectura del release, notas, intervalo.
- `test/core/updates/app_update_service_test.dart`: consulta, 12 h, omitir, descarga con hash
  (alterada, cortada, cancelada, reutilizada, limpieza de versiones anteriores).
