-- Ronda 4: eliminar la cuenta desde Configuración.
--
-- El cliente no puede borrar su propio usuario de `auth.users` con la llave
-- anon, así que se expone una función SECURITY DEFINER que solo borra a quien
-- la invoca (`auth.uid()`), nunca a otro usuario: no recibe parámetros.
--
-- Todas las tablas del usuario (`profiles`, `playlists`, `playlist_tracks`,
-- `saved_albums`, `listening_history`, `user_stats_monthly`,
-- `ai_rate_limit_requests`) referencian `auth.users(id)` con
-- `ON DELETE CASCADE`, así que borrar el usuario borra todo lo suyo en la
-- misma transacción. Al liberarse la fila de `auth.users`, también se libera
-- el cupo del límite de 250 cuentas (7.H).
CREATE OR REPLACE FUNCTION public.delete_my_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  uid uuid := auth.uid();
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'No hay sesión activa' USING ERRCODE = '42501';
  END IF;
  DELETE FROM auth.users WHERE id = uid;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_my_account() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_my_account() FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_my_account() TO authenticated;
