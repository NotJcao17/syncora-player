import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../player_models.dart';

/// Formato de sesión persistida del modelo de cola dual (Fase 7.A).
///
/// Sesiones guardadas en el formato viejo (`queue`/`currentIndex` planos) o
/// que no matcheen exactamente este esquema se descartan por completo (ver
/// 7.A.6 del plan) — es más simple y seguro que intentar migrarlas.
class PlayerSessionData {
  final SyncoraTrack? currentTrack;
  final QueueOrigin? currentOrigin;
  final List<SyncoraTrack> manualQueue;
  final List<SyncoraTrack> autoQueue;
  final List<SyncoraTrack> originalContextTracks;
  final List<HistoryEntry> history;
  final int positionSeconds;
  final double volume;
  final SyncoraRepeatMode repeatMode;
  final bool shuffle;
  final String? activeContextId;

  const PlayerSessionData({
    this.currentTrack,
    this.currentOrigin,
    required this.manualQueue,
    required this.autoQueue,
    required this.originalContextTracks,
    required this.history,
    required this.positionSeconds,
    this.volume = 1.0,
    required this.repeatMode,
    required this.shuffle,
    this.activeContextId,
  });

  Map<String, dynamic> toJson() => {
        // Marca de esquema explícita: si en el futuro este shape vuelve a
        // cambiar, basta con subir este número para invalidar sesiones viejas
        // sin depender de heurísticas sobre qué claves faltan.
        'schemaVersion': 2,
        'currentTrack': currentTrack?.toJson(),
        'currentOrigin': currentOrigin?.name,
        'manualQueue': manualQueue.map((t) => t.toJson()).toList(),
        'autoQueue': autoQueue.map((t) => t.toJson()).toList(),
        'originalContextTracks': originalContextTracks.map((t) => t.toJson()).toList(),
        'history': history.map((h) => h.toJson()).toList(),
        'positionSeconds': positionSeconds,
        'volume': volume,
        'repeatMode': repeatMode.name,
        'shuffle': shuffle,
        'activeContextId': activeContextId,
      };

  /// Devuelve `null` si `json` no matchea el esquema nuevo (incluye el
  /// formato viejo `queue`/`currentIndex`), en vez de lanzar o intentar
  /// migrar. El llamador debe tratar `null` como "sin sesión guardada".
  static PlayerSessionData? fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 2) return null;
    if (!json.containsKey('manualQueue') || !json.containsKey('autoQueue')) {
      return null;
    }

    try {
      final manualQueue = (json['manualQueue'] as List<dynamic>?)
              ?.map((item) => SyncoraTrack.fromJson(item as Map<String, dynamic>))
              .toList() ??
          [];
      final autoQueue = (json['autoQueue'] as List<dynamic>?)
              ?.map((item) => SyncoraTrack.fromJson(item as Map<String, dynamic>))
              .toList() ??
          [];
      final originalContextTracks = (json['originalContextTracks'] as List<dynamic>?)
              ?.map((item) => SyncoraTrack.fromJson(item as Map<String, dynamic>))
              .toList() ??
          [];

      // P0.5: el historial se parsea en su propio try/catch, aislado del
      // resto. Una entrada corrupta ahí NO debe tirar currentTrack, ambas
      // colas y la posición guardada — degrada a historial vacío en vez de
      // descartar toda la sesión.
      List<HistoryEntry> history = [];
      try {
        history = (json['history'] as List<dynamic>?)
                ?.map((item) => HistoryEntry.fromJson(item as Map<String, dynamic>))
                .toList() ??
            [];
      } catch (_) {
        history = [];
      }

      final currentTrackJson = json['currentTrack'] as Map<String, dynamic>?;
      final currentTrack = currentTrackJson != null ? SyncoraTrack.fromJson(currentTrackJson) : null;

      final originName = json['currentOrigin'] as String?;
      final currentOrigin = originName != null
          ? QueueOrigin.values.firstWhere(
              (e) => e.name == originName,
              orElse: () => QueueOrigin.auto,
            )
          : null;

      final modeName = json['repeatMode'] as String? ?? 'off';
      final repeatMode = SyncoraRepeatMode.values.firstWhere(
        (e) => e.name == modeName,
        orElse: () => SyncoraRepeatMode.off,
      );

      final volume = (json['volume'] as num?)?.toDouble() ?? 1.0;

      return PlayerSessionData(
        currentTrack: currentTrack,
        currentOrigin: currentOrigin,
        manualQueue: manualQueue,
        autoQueue: autoQueue,
        originalContextTracks: originalContextTracks,
        history: history,
        positionSeconds: (json['positionSeconds'] as num?)?.toInt() ?? 0,
        volume: volume.clamp(0.0, 1.0),
        repeatMode: repeatMode,
        shuffle: json['shuffle'] as bool? ?? false,
        activeContextId: json['activeContextId'] as String?,
      );
    } catch (_) {
      // Cualquier forma inesperada dentro de las listas también se trata
      // como "sesión no reconocida" — descartar es más seguro que crashear.
      return null;
    }
  }
}

class PlayerSessionStorage {
  /// Permite apuntar el archivo de sesión a una ruta concreta en tests
  /// (`getApplicationSupportDirectory` necesita el canal de plataforma de
  /// `path_provider`, que no existe en un test unitario). En producción se
  /// omite y la ruta se resuelve como siempre.
  PlayerSessionStorage({File? overrideFile}) : _sessionFile = overrideFile;

  File? _sessionFile;

  /// Última sesión pendiente de escribir. El controlador llama a
  /// [saveSession] en cada play/pause/next/cambio de cola y, desde el
  /// guardado periódico de posición, cada 5 s — un ritmo al que dos
  /// escrituras se solapaban con facilidad.
  PlayerSessionData? _pending;

  /// Escritura en curso, si la hay. Junto con [_pending] forma un
  /// *single-flight con coalescing*: nunca hay dos escrituras a la vez, y
  /// una ráfaga de N guardados se colapsa en como mucho dos.
  Future<void>? _writeLoop;

  Future<File> _getFile() async {
    if (_sessionFile != null) return _sessionFile!;
    final dir = await getApplicationSupportDirectory();
    _sessionFile = File('${dir.path}/syncora_player_session.json');
    return _sessionFile!;
  }

  Future<void> saveSession({
    required SyncoraTrack? currentTrack,
    required QueueOrigin? currentOrigin,
    required List<SyncoraTrack> manualQueue,
    required List<SyncoraTrack> autoQueue,
    required List<SyncoraTrack> originalContextTracks,
    required List<HistoryEntry> history,
    required int positionSeconds,
    double volume = 1.0,
    required SyncoraRepeatMode repeatMode,
    required bool shuffle,
    String? activeContextId,
  }) async {
    _pending = PlayerSessionData(
      currentTrack: currentTrack,
      currentOrigin: currentOrigin,
      manualQueue: manualQueue,
      autoQueue: autoQueue,
      originalContextTracks: originalContextTracks,
      history: history,
      positionSeconds: positionSeconds,
      volume: volume,
      repeatMode: repeatMode,
      shuffle: shuffle,
      activeContextId: activeContextId,
    );

    final running = _writeLoop;
    if (running != null) return running;
    final loop = _drainPending();
    _writeLoop = loop;
    return loop;
  }

  Future<void> _drainPending() async {
    try {
      while (_pending != null) {
        final data = _pending!;
        _pending = null;
        await _writeAtomically(data);
      }
    } finally {
      _writeLoop = null;
    }
  }

  /// Escribe a un temporal y lo renombra encima del definitivo.
  ///
  /// El renombrado es atómico en Windows y en Android, así que el archivo de
  /// sesión nunca puede quedar a medias. Antes se hacía `writeAsString`
  /// directo sobre el archivo final: eso lo trunca primero y lo llena
  /// después, así que un cierre de la app (o una segunda escritura solapada)
  /// a mitad dejaba un JSON incompleto. `loadSession` no puede distinguir
  /// eso de "no hay sesión" y devuelve `null` — es decir, **se perdía la
  /// sesión entera**: la playlist que sonaba, la cola manual y la posición.
  Future<void> _writeAtomically(PlayerSessionData data) async {
    try {
      final file = await _getFile();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(data.toJson()), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('[PlayerSessionStorage] Error guardando sesión: $e');
    }
  }

  Future<PlayerSessionData?> loadSession() async {
    try {
      final file = await _getFile();
      if (!await file.exists()) return null;
      final jsonStr = await file.readAsString();
      if (jsonStr.trim().isEmpty) return null;
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      return PlayerSessionData.fromJson(data);
    } catch (e) {
      debugPrint('[PlayerSessionStorage] Error cargando sesión: $e');
      return null;
    }
  }
}
