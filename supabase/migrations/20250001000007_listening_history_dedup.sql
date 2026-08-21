-- Fase 7.0.1: red de seguridad contra filas duplicadas en listening_history.
--
-- Hasta ahora _syncListeningHistoryInternal() (lib/data/sync/sync_service.dart)
-- insertaba con un `.insert()` plano y sin ninguna marca local de "ya
-- sincronizado" -- en cuanto se activó el registro real de escuchas
-- (ListeningHistoryDao.recordEntry(), Fase 7.0.2), cada sincronización habría
-- reinsertado las mismas filas. La corrección principal es la columna
-- Drift `syncedAt` (ver lib/data/local_db/syncora_database.dart), pero esa
-- marca es local -- una reinstalación del dispositivo, o un fallo justo
-- entre el upsert remoto y el marcado local, la pierde. Esta clave natural
-- única es la red de seguridad del lado del servidor: permite usar
-- `upsert(..., onConflict: 'user_id,track_id,listened_at')` en
-- SupabaseHistoryRepository.insertListeningHistory() para que un reintento
-- (con el mismo listened_at, que el cliente ya no recalcula por intento)
-- nunca duplique la fila, aunque el marcado local haya fallado.
CREATE UNIQUE INDEX IF NOT EXISTS idx_listening_history_dedup
  ON public.listening_history (user_id, track_id, listened_at);
