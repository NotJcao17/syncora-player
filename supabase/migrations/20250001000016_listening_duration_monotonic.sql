-- La duración de una escucha nunca puede decrecer.
--
-- SÍNTOMA: con música sonando a la vez en el PC y en el móvil, los minutos
-- subían y al recargar bajaban.
--
-- CAUSA: cada dispositivo se baja el historial de los demás
-- (`_pullRemoteHistory`). Esa copia local guarda la duración que la escucha
-- tenía EN EL MOMENTO DE LA DESCARGA — y una escucha que todavía está
-- sonando en el otro aparato sigue creciendo después. Bastaba con que algo
-- volviera a marcar esa copia como "pendiente de subir" (lo hacía el relleno
-- de géneros) para que el push la mandara de vuelta y **pisara el valor bueno
-- con uno viejo y más bajo**.
--
-- El lado del cliente ya está corregido (`applyGenreToAlbum` no toca filas
-- ajenas, y `insertRemoteEntries` refresca la copia cuando la nube trae un
-- valor mayor). Esto es la red de seguridad del lado del servidor: da igual
-- qué cliente, de qué versión, mande qué — una escucha solo puede crecer.
--
-- Es correcto para este dato por su propia naturaleza: `duration_listened_ms`
-- es tiempo acumulado de una reproducción concreta, y el tiempo no se
-- desescucha. Un `upsert` que traiga menos de lo ya guardado siempre es una
-- carrera o una copia rancia, nunca una corrección legítima.
CREATE OR REPLACE FUNCTION public.listening_history_keep_max_duration()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.duration_listened_ms IS NULL THEN
    NEW.duration_listened_ms := OLD.duration_listened_ms;
  ELSIF OLD.duration_listened_ms IS NOT NULL
        AND NEW.duration_listened_ms < OLD.duration_listened_ms THEN
    NEW.duration_listened_ms := OLD.duration_listened_ms;
  END IF;

  -- El género sí puede rellenarse después (se resuelve por álbum en segundo
  -- plano), pero no borrarse: un cliente que todavía no lo tenga resuelto no
  -- debe dejar en NULL uno que ya estaba puesto.
  IF NEW.genre IS NULL AND OLD.genre IS NOT NULL THEN
    NEW.genre := OLD.genre;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_listening_history_keep_max_duration ON public.listening_history;

CREATE TRIGGER trg_listening_history_keep_max_duration
  BEFORE UPDATE ON public.listening_history
  FOR EACH ROW
  EXECUTE FUNCTION public.listening_history_keep_max_duration();
