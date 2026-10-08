-- Ronda 7: ¿existe todavía esta cuenta? Para cuando Supabase cerró la sesión
-- solo y ya no hay token con el que preguntar.
--
-- Caso: se elimina la cuenta en el PC; el celular abre la app más de una hora
-- después (con la app cerrada o en segundo plano no renueva su token). La
-- renovación se rechaza porque los tokens se borraron con la cuenta, y
-- Supabase cierra la sesión sin decir por qué. El mismo error sale si la
-- sesión se cerró en el servidor, así que con eso no se distingue. La app
-- pregunta aquí por el id de la cuenta dueña de sus datos locales: si ya no
-- existe, los borra y lo explica.
--
-- Callable sin sesión (anon). Solo responde sí/no para un UUID concreto: no
-- devuelve ningún dato de la cuenta, y un UUID aleatorio de 122 bits no se
-- puede adivinar ni enumerar.
CREATE OR REPLACE FUNCTION public.account_exists(account_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (SELECT 1 FROM auth.users WHERE id = account_id);
$$;

REVOKE ALL ON FUNCTION public.account_exists(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.account_exists(uuid) TO anon, authenticated;
