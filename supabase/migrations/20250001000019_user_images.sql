-- Portadas propias de playlists y foto de perfil (docs/fases/portadas_y_fotos.md).
--
-- Las imágenes viven en Cloudflare R2, no aquí: la base de datos solo guarda
-- su URL pública. `playlists.cover_url` ya existía y acepta cualquier texto;
-- para la foto de perfil hace falta una columna nueva. NULL = sin foto, se
-- usa la semilla de DiceBear (`avatar_seed`) como hasta ahora. La política
-- `profiles_own` (FOR ALL, `auth.uid() = id`) ya cubre la actualización.
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS avatar_url TEXT;

-- Rate limit de la Edge Function `user-images`. Mismo diseño que
-- `ai_rate_limit_requests` (migración 8): registro de eventos con ventana
-- deslizante de 1 hora, sin política de DELETE ni UPDATE para que ni el
-- cliente ni la función puedan resetear su propio cupo con el JWT del
-- usuario. Existe porque R2 cobra por operación a partir de cierto volumen y
-- exige una tarjeta registrada aunque se use dentro del plan gratuito.
CREATE TABLE public.image_upload_requests (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_image_upload_requests_user_time
  ON public.image_upload_requests (user_id, requested_at);

ALTER TABLE public.image_upload_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY "image_upload_requests_select_own"
  ON public.image_upload_requests FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "image_upload_requests_insert_own"
  ON public.image_upload_requests FOR INSERT
  WITH CHECK (auth.uid() = user_id);
