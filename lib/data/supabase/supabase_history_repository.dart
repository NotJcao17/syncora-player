import 'dart:io';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseHistoryRepository {
  bool get _isTestEnv => Platform.environment.containsKey('FLUTTER_TEST');

  SupabaseClient? get _client {
    if (_isTestEnv) return null;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  /// Sube una entrada de historial de escucha. Usa `upsert` con una clave
  /// natural (`user_id, track_id, listened_at`, ver migración
  /// `20250001000007_listening_history_dedup.sql`) en vez de un `insert`
  /// plano: es la red de seguridad de la Fase 7.0.1 contra duplicados si el
  /// marcado local de `syncedAt` llega a fallar o una reinstalación reenvía
  /// filas ya subidas — `listenedAt` debe ser el valor fijo que ya trae la
  /// fila local (nunca `DateTime.now()` en cada intento), para que la clave
  /// natural sea estable entre reintentos.
  Future<void> insertListeningHistory({
    required int trackId,
    required DateTime listenedAt,
    int? artistId,
    int? albumId,
    String? genre,
    int? durationListenedMs,
  }) async {
    final client = _client;
    if (client == null) return;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    await client.from('listening_history').upsert(
      {
        'user_id': userId,
        'track_id': trackId,
        'artist_id': artistId,
        'album_id': albumId,
        'genre': genre,
        'duration_listened_ms': durationListenedMs,
        'listened_at': listenedAt.toUtc().toIso8601String(),
      },
      onConflict: 'user_id,track_id,listened_at',
    );
  }

  /// Sube un lote de escuchas en **una sola petición** (H-S4).
  ///
  /// Antes el push hacía un `upsert` por fila: subir 200 escuchas acumuladas
  /// tras un rato sin conexión eran 200 viajes de red, cada uno con su
  /// handshake y su coste en el plan free. PostgREST acepta un array en el
  /// cuerpo y aplica el mismo `onConflict`, así que el lote entero cuesta lo
  /// que costaba una fila.
  ///
  /// Devuelve `true` si el lote se subió. No se traga los errores: el
  /// llamador necesita saberlo para no marcar como sincronizado algo que no
  /// llegó.
  Future<bool> insertListeningHistoryBatch(List<Map<String, dynamic>> entries) async {
    if (entries.isEmpty) return true;
    final client = _client;
    if (client == null) return false;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return false;

    await client.from('listening_history').upsert(
          [
            for (final e in entries)
              {
                'user_id': userId,
                'track_id': e['track_id'],
                'artist_id': e['artist_id'],
                'album_id': e['album_id'],
                'genre': e['genre'],
                'duration_listened_ms': e['duration_listened_ms'],
                'listened_at': (e['listened_at'] as DateTime).toUtc().toIso8601String(),
              },
          ],
          onConflict: 'user_id,track_id,listened_at',
        );
    return true;
  }

  /// Historial del usuario en la nube desde [since].
  ///
  /// **Por qué hacía falta:** hasta ahora la sincronización de historial era de
  /// una sola dirección — cada dispositivo subía lo suyo y no bajaba nada — así
  /// que `listening_history` local era en realidad "lo que escuché *en este
  /// aparato*". Todo lo que se deriva de ahí (On Repeat, los mixes, "Novedades
  /// de tus artistas", las estadísticas semanales) salía distinto en el PC que
  /// en el móvil, cuando debería ser lo mismo.
  Future<List<Map<String, dynamic>>> fetchListeningHistory({
    required DateTime since,
    int limit = 1000,
  }) async {
    final client = _client;
    if (client == null) return [];
    final userId = client.auth.currentUser?.id;
    if (userId == null) return [];

    final rows = await client
        .from('listening_history')
        .select()
        .eq('user_id', userId)
        .gte('listened_at', since.toUtc().toIso8601String())
        .order('listened_at', ascending: false)
        .limit(limit);

    return List<Map<String, dynamic>>.from(rows as List);
  }
}
