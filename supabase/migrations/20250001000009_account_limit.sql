-- Fase 7.H: límite de 250 cuentas en la nube (Documento Maestro §4.5, D-22).
--
-- app_config es una tabla de configuración de una sola fila -- el tope vive
-- acá, no hardcodeado en la función, para poder subirlo con un UPDATE desde
-- el SQL Editor del dashboard sin redeploy de nada (ver "Operación: ver y
-- administrar cuentas" en docs/plan_fase_7.md).
CREATE TABLE public.app_config (
  id BOOLEAN PRIMARY KEY DEFAULT TRUE CONSTRAINT app_config_singleton CHECK (id),
  max_accounts INTEGER NOT NULL DEFAULT 250
);

INSERT INTO public.app_config (id, max_accounts) VALUES (TRUE, 250);

ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;

-- Lectura pública de la sola fila -- no hay nada sensible acá, y deja abierta
-- la puerta a que el cliente algún día muestre el cupo sin depender solo del
-- mensaje de error del hook. Sin política de INSERT/UPDATE/DELETE a
-- propósito: los cambios de tope se hacen desde el SQL Editor con privilegios
-- de servicio, nunca desde el cliente autenticado.
CREATE POLICY "app_config_select_all"
  ON public.app_config FOR SELECT
  USING (true);

-- Fase 7.H.2: Auth Hook "Before User Created" -- cuenta auth.users y
-- rechaza el registro si ya se alcanzó el tope. Función de Postgres, no Edge
-- Function (recomendación del plan): solo necesita contar filas, no hay
-- motivo para pagar el arranque de una función serverless en cada signup.
--
-- Contrato verificado contra la documentación de Supabase (agosto 2026,
-- guía "Before User Created Hook"): recibe `event jsonb` y devuelve `jsonb`;
-- para rechazar, `{"error": {"message": ..., "http_code": ...}}`; para
-- permitir, `{}`. Se aplica tanto a registro por correo/contraseña como a
-- OAuth (Google) -- confirmado en la misma guía ("runs before a new user is
-- created", independiente del proveedor). Aun así, 7.H.5 pide probar ambos
-- caminos explícitamente en el proyecto real: hay un bug conocido de la
-- plataforma (7.H.4) donde el transporte del hook puede devolver
-- "Invalid payload sent to hook" genérico en vez de este mensaje.
CREATE OR REPLACE FUNCTION public.before_user_created_account_limit(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_count INTEGER;
  max_allowed INTEGER;
BEGIN
  SELECT max_accounts INTO max_allowed FROM public.app_config WHERE id = TRUE;
  -- Defensa en profundidad (hallazgo de la revisión independiente): si la
  -- fila singleton llegara a faltar por algún motivo, `max_allowed` queda
  -- NULL y `current_count >= NULL` evalúa a NULL -- falsy en un `IF` de
  -- plpgsql -- así que sin este fallback la función "fail-abre" (deja
  -- registrar sin límite en silencio) en vez de "fail-cerrar". Se usa el
  -- mismo valor por defecto que la migración siembra (250, D-22) para que
  -- el comportamiento degrade al esperado, no a ninguno de los dos extremos.
  IF max_allowed IS NULL THEN
    max_allowed := 250;
  END IF;
  SELECT COUNT(*) INTO current_count FROM auth.users;

  IF current_count >= max_allowed THEN
    RETURN jsonb_build_object(
      'error', jsonb_build_object(
        'message', 'Las cuentas con nube de Syncora Player están llenas por ahora. Puedes usar la app sin cuenta (modo local) mientras se libera cupo.',
        'http_code', 403
      )
    );
  END IF;

  RETURN '{}'::jsonb;
END;
$$;

-- El hook lo invoca el rol `supabase_auth_admin`, no el usuario final -- se
-- le da permiso explícito y se lo revoca a todos los demás roles (patrón
-- documentado por Supabase para hooks de Postgres).
GRANT EXECUTE ON FUNCTION public.before_user_created_account_limit TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION public.before_user_created_account_limit FROM authenticated, anon, public;

-- NOTA -- 7.H.3: activar este hook es configuración de PROYECTO (Dashboard
-- de Supabase -> Authentication -> Hooks -> "Before User Created" ->
-- seleccionar esta función), no viaja en las migraciones. Documentado en
-- docs/fases/fase_7_h.md para no perder el paso si se recrea el proyecto.
