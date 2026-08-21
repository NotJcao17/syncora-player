-- Fase 7.E.2: rate limit por usuario para la Edge Function `ai-assistant`.
--
-- Diseño elegido: registro de eventos (una fila por petición aceptada), no un
-- contador de "ventana fija" (user_id, window_start, count). Con un registro
-- de eventos el límite es una ventana deslizante real de 1 hora
-- (`COUNT(*) WHERE requested_at > now() - interval '1 hour'`), sin el efecto
-- de "doble cupo" que tendría un bucket fijo justo en el borde entre dos
-- ventanas.
--
-- Esta tabla NO se poda desde el cliente ni desde la Edge Function (revisado
-- y corregido tras el review de 7.E): la primera versión le daba a cada
-- usuario permiso RLS de DELETE sobre sus propias filas para que la propia
-- función pudiera podar filas viejas usando el JWT del usuario -- pero esa
-- misma política le daba ese permiso también AL CLIENTE directamente, sin
-- pasar por la Edge Function en absoluto: cualquier usuario autenticado
-- podía llamar al REST/SDK de Supabase con su propio JWT y borrar su propio
-- historial de peticiones a voluntad, reseteando su cupo y dejando el rate
-- limit completo opcional para quien inspeccionara el tráfico de la app. La
-- poda se elimina por completo por ahora: la corrección del límite no
-- depende de ella (`checkRateLimit` ya filtra por
-- `requested_at > windowStart`, así que las filas viejas sin borrar no
-- afectan el conteo, solo el tamaño de la tabla). Queda pendiente de un job
-- `pg_cron` con privilegios de servidor (mismo patrón que usará la Fase 7.G
-- para podar `listening_history`/agregar `user_stats_monthly`) -- no
-- implementado todavía, ni siquiera definido en el plan. Con el tope de 250
-- cuentas (Fase 7.H) y el límite de 20 peticiones/hora, el peor caso
-- realista de crecimiento sin ese cron sigue siendo un volumen de filas
-- pequeño durante varios meses.
CREATE TABLE public.ai_rate_limit_requests (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Cubre el COUNT de la ventana deslizante (filtra por user_id y compara
-- requested_at) y también servirá para el futuro DELETE de poda del cron.
CREATE INDEX idx_ai_rate_limit_requests_user_time
  ON public.ai_rate_limit_requests (user_id, requested_at);

ALTER TABLE public.ai_rate_limit_requests ENABLE ROW LEVEL SECURITY;

-- La Edge Function inicializa su cliente de Supabase SIEMPRE con el JWT del
-- usuario que invoca (nunca SERVICE_ROLE_KEY, Documento Maestro §4.3 punto
-- 2), así que estas políticas estándar de `auth.uid() = user_id` ya cubren
-- lectura e inserción (registrar la petición actual) sin necesitar ningún
-- privilegio elevado. A propósito NO hay política de DELETE (ni de UPDATE):
-- ni el cliente ni la Edge Function deben poder borrar/alterar filas de rate
-- limit con el JWT del usuario -- ver la nota de seguridad arriba. La poda
-- futura, cuando se implemente, correrá como job de servidor con
-- SERVICE_ROLE_KEY (fuera de RLS), no como una política más permisiva aquí.
CREATE POLICY "ai_rate_limit_requests_select_own"
  ON public.ai_rate_limit_requests FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "ai_rate_limit_requests_insert_own"
  ON public.ai_rate_limit_requests FOR INSERT
  WITH CHECK (auth.uid() = user_id);
