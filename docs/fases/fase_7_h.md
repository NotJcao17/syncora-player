# Syncora Player — Fase 7.H: Límite de cuentas (250)

## Resumen

Tope de 250 cuentas en la nube (Documento Maestro §4.5, D-22), implementado con un Auth Hook de
Postgres "Before User Created" que cuenta `auth.users` y rechaza el registro si ya se alcanzó el
tope. El tope vive en una tabla de configuración (`app_config.max_accounts`), no hardcodeado, para
poder subirlo con un `UPDATE` desde el SQL Editor sin redeploy de nada.

## Componentes

- **`supabase/migrations/20250001000009_account_limit.sql`** (nuevo):
  - Tabla `app_config`, fila única (`id BOOLEAN PRIMARY KEY DEFAULT TRUE` con `CHECK (id)` como
    guarda de singleton), `max_accounts INTEGER NOT NULL DEFAULT 250`, sembrada con `250`. RLS con
    solo política de `SELECT` pública — sin `INSERT`/`UPDATE`/`DELETE` desde el cliente a
    propósito, los cambios de tope se hacen desde el dashboard con privilegios de servicio.
  - Función `before_user_created_account_limit(event jsonb) RETURNS jsonb`, `SECURITY DEFINER`,
    `SET search_path = public`: cuenta `auth.users`, compara contra `max_accounts`, y devuelve
    `{"error": {"message": ..., "http_code": 403}}` para rechazar o `{}` para permitir. Contrato
    verificado contra la documentación de Supabase (agosto 2026, guía "Before User Created Hook")
    antes de escribirlo — confirmado que recibe `event jsonb`/devuelve `jsonb` con ese shape
    exacto, y que se aplica **tanto** a registro por correo/contraseña **como** a OAuth (Google),
    cerrando la duda de 7.H.5.
  - `GRANT EXECUTE ... TO supabase_auth_admin` + `REVOKE ... FROM authenticated, anon, public`
    (patrón documentado por Supabase para hooks de Postgres — solo el rol interno de Auth puede
    invocar la función, nadie más).
- **`lib/features/auth/services/account_limit_error.dart`** (nuevo) — función pura
  `looksLikeAccountLimitError(String message)` + constante `accountLimitMessage`, extraídas fuera
  de `auth_screen.dart` específicamente para poder testear la detección sin mockear Supabase (el
  flujo de auth real no tiene el patrón de invoker inyectable que sí tiene
  `AiAssistantService`/7.E). Reconoce **dos** formas del mismo error, no solo el mensaje
  personalizado: hay un bug conocido de la plataforma Supabase donde, al rechazar un hook con un
  mensaje personalizado, la respuesta que llega al cliente puede ser el genérico "Invalid payload
  sent to hook" en vez del texto propio (7.H.4 lo pedía explícitamente).
- **`lib/features/auth/screens/auth_screen.dart`** — usa el helper de arriba en dos puntos:
  - `_handleSubmitForm`, en el `catch (AuthException e)` ya existente (login/registro por
    correo/contraseña).
  - `_handleGoogleSignIn`, en el `catch` genérico (el flujo de Windows envuelve el error de OAuth
    en una `AuthException` propia dentro de `DesktopAuthService`; se distingue `e is AuthException`
    del resto para no perder el mensaje real en el `toString()` genérico).
  - Nuevo campo `_accountLimitReached`, reseteado junto con `_errorMessage` en cada intento nuevo
    (`_handleSubmitForm`, `_handleGoogleSignIn`) y al cambiar de pestaña Login/Registro — evita que
    el banner quede "pegado" mostrando un estado que ya no aplica.
  - Banner ámbar propio (mismo estilo que la advertencia existente de "no hay recuperación de
    contraseña" en la pestaña Registro) en vez de reusar el banner rojo genérico de error — son
    mutuamente excluyentes, nunca se muestran los dos a la vez, porque el `catch` que detecta el
    cupo lleno hace `_accountLimitReached = true` en vez de escribir `_errorMessage`.
- **`test/features/auth/account_limit_error_test.dart`** (nuevo) — 4 tests del detector puro:
  mensaje personalizado, bug genérico de la plataforma, insensibilidad a mayúsculas, y que errores
  de auth normales (credenciales inválidas, email ya registrado, contraseña corta) no den falso
  positivo.

## Decisión de secuenciación documentada (no un hallazgo, no una omisión)

El plan original (`docs/plan_fase_7.md`, 7.H.4) pide un "botón directo a usar sin cuenta (7.I)"
junto al mensaje de cupo lleno. **No se agregó en esta fase**: 7.I (modo local) todavía no existe
en el código en este punto — no hay `localModeProvider` ni pantalla a la que apuntar. Un botón que
no lleva a ningún lado real sería peor que no mostrarlo (regla del proyecto: no dejar
implementaciones a medias). El banner y el mensaje están listos y probados; el botón se cablea en
7.I.3 cuando exista el destino real. Documentado en el código
(`auth_screen.dart`, comentario junto a `_accountLimitReached`) para que quien implemente 7.I lo
encuentre sin tener que releer este documento.

## Revisión independiente

Fase con riesgo real (toca `auth`, categoría explícitamente marcada en la metodología de
`CLAUDE.md` como una de las que sí requieren un subagente de revisión separado, a diferencia de
7.F.3/7.F.4). Revisión hecha por un subagente Sonnet aparte del que implementó, sobre el diff
completo sin commitear. Encontró 3 hallazgos reales, los 3 corregidos antes de cerrar la fase:

1. **[Corregido, el más severo]** En Android/iOS, `signInWithOAuth` solo abre el navegador y
   retorna de inmediato -- el resultado real (sesión o error) llega después por el deep link que
   procesa `_handleAuthDeepLink` en `main.dart`, **fuera** de `auth_screen.dart`. Antes de la
   corrección, si ese callback traía un error en vez de tokens/código (incluido el rechazo del
   hook de 7.H.2 por cupo lleno), el código no hacía nada visible -- **cualquier** error de OAuth
   en esas plataformas, no solo el de cupo, desaparecía en silencio. Corregido con un bridge nuevo,
   `lib/features/auth/services/auth_deep_link_errors.dart` (`StreamController<String>` broadcast):
   `_handleAuthDeepLink` detecta `error`/`error_description` en la URL (query o fragment) y lo
   publica ahí en vez de intentar extraer una sesión inexistente; `auth_screen.dart` se suscribe en
   `initState` (fuera de entorno de test) y aplica la misma detección
   `looksLikeAccountLimitError` que ya usaban los otros dos catches, cancelando la suscripción en
   `dispose`.
2. **[Corregido]** `before_user_created_account_limit`: si la fila singleton de `app_config`
   llegara a faltar, `max_allowed` queda `NULL` y `current_count >= NULL` evalúa a `NULL` --
   falsy en plpgsql -- así que la función "fallaba abierta" (dejaba registrar sin límite, en
   silencio) en vez de fallar cerrada. Corregido con un fallback explícito a `250` (mismo valor
   que siembra la migración, D-22) si `max_allowed IS NULL`.
3. **[Documentado, no requiere código]** El match de `"invalid payload sent to hook"` en
   `looksLikeAccountLimitError` asume que este es, por ahora, el único Auth Hook del proyecto -- si
   se agrega otro más adelante (ej. en 7.I), un fallo genérico de transporte de ESE hook también se
   reportaría como "cupo lleno". Aceptado a propósito por ahora; comentario agregado en el propio
   archivo para que quien agregue un segundo hook lo revise.

Sin hallazgos en el contrato SQL del hook (firma, `SECURITY DEFINER`/`search_path`, GRANT/REVOKE
restringido a `supabase_auth_admin`), la política RLS de `app_config`, ni el manejo de estado del
banner ámbar en `auth_screen.dart` (reset correcto en reintento/cambio de pestaña, mutuamente
excluyente con el banner rojo genérico).

## Verificación de pruebas

- `flutter analyze`: limpio (28 lints `info` preexistentes, mismo baseline que el resto de la
  Fase 7).
- `flutter test`: **313 tests, 0 fallos** (suite completa, una sola corrida antes de comitear --
  309 del baseline + 4 nuevos de `test/features/auth/account_limit_error_test.dart`).

## Pendiente / pasos manuales para el desarrollador humano

Igual que el resto de la infraestructura de Supabase de esta fase (Edge Functions, rate limit),
**activar el hook es configuración de proyecto, no viaja en las migraciones**:

1. Aplicar la migración `20250001000009_account_limit.sql` (`supabase db push` o equivalente).
2. Dashboard de Supabase → **Authentication → Hooks** → "Before User Created" → seleccionar la
   función `public.before_user_created_account_limit`.
3. **Probar explícitamente los dos caminos de registro** (correo/contraseña y Google OAuth) contra
   el proyecto real, no asumir que ambos quedan cubiertos solo porque la documentación de Supabase
   dice que el hook aplica a los dos — 7.H.5 lo pide a propósito porque es exactamente el tipo de
   cosa fácil de dar por sentado y descubrir tarde que no.
4. Verificar también el camino del bug conocido: forzar el rechazo (bajar `max_accounts` a un
   número ya alcanzado en un proyecto de prueba) y confirmar qué mensaje llega realmente al
   cliente en la práctica — el personalizado o el genérico "Invalid payload sent to hook" — para
   confirmar que `looksLikeAccountLimitError` cubre el caso real, no solo el documentado.

Operación día a día (ver cuentas, borrar cuentas de prueba, subir el tope) ya está documentada en
`docs/plan_fase_7.md`, sección "Operación: ver y administrar cuentas" — no se duplica acá.
