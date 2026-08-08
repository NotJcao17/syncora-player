# Syncora Player — Configuración de Auth (Contexto Pre-Fase 5)

Este documento registra las decisiones de arquitectura y configuración de Supabase Auth
realizadas **manualmente antes de iniciar la Fase 5**, para que el agente desarrollador
las lea antes de implementar cualquier código de autenticación.

---

## Configuración ya realizada en Supabase Dashboard

- **Provider Google:** Activado. Client ID y Client Secret configurados (obtenidos
  desde Google Cloud Console, proyecto "Syncora Player"). OAuth consent screen en modo
  Testing por ahora (solo usuarios de prueba pueden iniciar sesión con Google
  hasta que se publique en producción).
- **Provider Email:** Activado. "Confirm email" DESACTIVADO — el usuario queda
  logueado inmediatamente tras registrarse, sin correo de confirmación.
- "Secure email change" activado (sin efecto práctico relevante por ahora).
- **Authentication URL Configuration:**
  - Site URL: syncoraplayer://
  - Redirect URLs: syncoraplayer://login-callback

---

## Decisiones de Producto

### Metodo de login principal: Google

El plan Free de Supabase no permite enviar emails a usuarios reales sin un servidor
SMTP personalizado con dominio propio verificado. Por eso:

- Google Sign-In es el metodo PRINCIPAL y recomendado. El boton debe ser grande
  y prominente en la pantalla de Auth.
- Email/contrasena es un metodo SECUNDARIO, disponible pero visualmente
  subordinado al boton de Google.
- SIN recuperacion de contrasena: No implementar ningun flujo de "Olvide mi
  contrasena" en esta fase ni como placeholder. Se retomara si se configura SMTP con
  dominio propio en el futuro.
- El usuario debe ver una advertencia visible ANTES de completar el registro con
  email, indicando que no hay recuperacion de contrasena y recomendando usar Google.
- Sin verificacion de email ni MFA/TOTP en esta fase.
- Comportamiento post-registro con email: usuario queda logueado inmediatamente
  (NO mostrar pantalla de "revisa tu correo").

---

## Esquema de Deep Link: syncoraplayer://

Se usa syncoraplayer:// como esquema de deep link.

Reglas criticas:
- El applicationId/namespace de Android (com.syncora.syncora_player) NO se
  modifica. El deep link es independiente del applicationId.
- Se eligio un esquema sin puntos ni guiones bajos para evitar un bug conocido de
  Supabase/Google OAuth con redirect URLs que contienen guiones bajos.
- La callback URL completa es: syncoraplayer://login-callback

### Android

Requiere agregar un intent-filter en AndroidManifest.xml dentro de la activity
principal (com.ryanheise.audioservice.AudioServiceActivity):

```xml
<intent-filter>
  <action android:name="android.intent.action.VIEW" />
  <category android:name="android.intent.category.DEFAULT" />
  <category android:name="android.intent.category.BROWSABLE" />
  <data android:scheme="syncoraplayer" android:host="login-callback" />
</intent-filter>
```

### Windows

El esquema syncoraplayer:// ya esta registrado manualmente en el Registro de Windows
de la maquina del desarrollador (HKEY_CURRENT_USER\Software\Classes\syncoraplayer)
apuntando al ejecutable compilado en build\windows\x64\runner\Release\syncora_player.exe,
para pruebas locales de deep link. Esto es temporal/manual.

En el futuro debera reemplazarse por un script de instalador (Inno Setup o MSIX) que
registre esta entrada automaticamente en la maquina de cada usuario final durante la
instalacion. Tarea pendiente para la fase de empaquetado/distribucion, no ahora.

---

## Avatares: DiceBear Adventurer Neutral

- Estilo: adventurer-neutral
- URL base: https://api.dicebear.com/9.x/adventurer-neutral/svg?seed={seed}
- Flujo: El usuario puede elegir entre 24 opciones predefinidas (seeds fijos en un
  grid). El seed elegido se guarda en profiles.avatar_seed en Supabase. Por defecto
  al registrarse, el seed es el UUID del usuario.
- Renderizado: SvgPicture.network(url) usando flutter_svg.

---

## Tareas de Implementacion para el Agente en Fase 5

- Pantalla de Auth: boton principal "Continuar con Google" (signInWithOAuth,
  OAuthProvider.google, redirectTo: syncoraplayer://login-callback) y opcion
  secundaria de email/contrasena, visualmente menos prominente.
- Advertencia visible antes de enviar formulario de registro con email.
- intent-filter en AndroidManifest.xml para syncoraplayer://login-callback.
- Listener de supabase.auth.onAuthStateChange para detectar login completado
  y navegar a la pantalla principal.
- Verificar persistencia de sesion entre reinicios de la app.
- Selector de avatar con 24 seeds predefinidos (estilo adventurer-neutral).
  Guardar seed elegido en profiles.avatar_seed.

---

## Variables de Entorno del Agente

El agente asume que existe un archivo .env.local en la raiz del proyecto (en
.gitignore) con las siguientes variables configuradas:

SUPABASE_SERVICE_ROLE_KEY=eyJ...
SUPABASE_DB_URL=postgresql://postgres:PASSWORD@db.njkfudsyfzdkdvwizdag.supabase.co:5432/postgres

El agente las carga en la sesion de PowerShell con este bloque antes de usarlas:

```powershell
Get-Content .env.local | ForEach-Object {
    if ($_ -match '^([^#][^=]*)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process')
    }
}
```

Nunca escribe estas variables en ningun archivo versionado.

---

## BUG CONOCIDO: supabase link falla en CLI v2.112.0

El comando `supabase link --project-ref ...` falla con el siguiente error en la
version 2.112.0 del CLI (la mas reciente al momento de esta configuracion):

  failed to get api keys: SchemaError(Expected a string matching the RegExp
  ^(?:...)-02-29|...)T(...Z)$ at [2]["inserted_at"])

Causa: el CLI tiene un parser de fechas que no reconoce el formato que retorna
el API de Supabase actualmente. Es un bug del CLI, no de la configuracion.

SOLUCION PERMANENTE: NO usar `supabase link`. Usar siempre `supabase db push`
con el flag `--db-url` apuntando directamente a la base de datos:

```bash
supabase db push --db-url "$env:SUPABASE_DB_URL"
```

Esto bypasea completamente el paso de link y aplica las migraciones directamente.
El agente debe usar este comando en lugar de link+push en toda la Fase 5.

---

Fecha de configuracion: 2026-08-07
Actualizado: 2026-08-07 (bug supabase link + workaround --db-url)
