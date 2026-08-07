import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../player_models.dart';

class PlayerSessionData {
  final List<SyncoraTrack> queue;
  final int currentIndex;
  final int positionSeconds;
  final SyncoraRepeatMode repeatMode;
  final bool shuffle;

  const PlayerSessionData({
    required this.queue,
    required this.currentIndex,
    required this.positionSeconds,
    required this.repeatMode,
    required this.shuffle,
  });

  Map<String, dynamic> toJson() => {
        'queue': queue.map((t) => t.toJson()).toList(),
        'currentIndex': currentIndex,
        'positionSeconds': positionSeconds,
        'repeatMode': repeatMode.name,
        'shuffle': shuffle,
      };

  factory PlayerSessionData.fromJson(Map<String, dynamic> json) {
    final queueList = (json['queue'] as List<dynamic>?)
            ?.map((item) => SyncoraTrack.fromJson(item as Map<String, dynamic>))
            .toList() ??
        [];
    final modeName = json['repeatMode'] as String? ?? 'off';
    final repeatMode = SyncoraRepeatMode.values.firstWhere(
      (e) => e.name == modeName,
      orElse: () => SyncoraRepeatMode.off,
    );

    return PlayerSessionData(
      queue: queueList,
      currentIndex: json['currentIndex'] as int? ?? -1,
      positionSeconds: json['positionSeconds'] as int? ?? 0,
      repeatMode: repeatMode,
      shuffle: json['shuffle'] as bool? ?? false,
    );
  }
}

class PlayerSessionStorage {
  File? _sessionFile;

  Future<File> _getFile() async {
    if (_sessionFile != null) return _sessionFile!;
    final dir = await getApplicationSupportDirectory();
    _sessionFile = File('${dir.path}/syncora_player_session.json');
    return _sessionFile!;
  }

  Future<void> saveSession({
    required List<SyncoraTrack> queue,
    required int currentIndex,
    required int positionSeconds,
    required SyncoraRepeatMode repeatMode,
    required bool shuffle,
  }) async {
    try {
      final file = await _getFile();
      final session = PlayerSessionData(
        queue: queue,
        currentIndex: currentIndex,
        positionSeconds: positionSeconds,
        repeatMode: repeatMode,
        shuffle: shuffle,
      );
      final jsonStr = jsonEncode(session.toJson());
      await file.writeAsString(jsonStr);
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
