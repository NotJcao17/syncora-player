import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/settings/app_settings_store.dart';
import 'player_models.dart';

/// Una canción que no se pudo reproducir (ronda 10).
class UnplayableEntry {
  const UnplayableEntry({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.reason,
    required this.at,
  });

  final String trackId;
  final String title;
  final String artist;
  final String reason;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'trackId': trackId,
        'title': title,
        'artist': artist,
        'reason': reason,
        'at': at.toIso8601String(),
      };

  static UnplayableEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = DateTime.tryParse(json['at'] as String? ?? '');
    if (at == null) return null;
    return UnplayableEntry(
      trackId: json['trackId'] as String? ?? '',
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
      at: at,
    );
  }
}

/// Registro de las canciones que no se pudieron reproducir, con fecha y
/// motivo (Configuración → Reproducción).
///
/// Es del dispositivo, como el resto de los ajustes (`AppSettingsStore`):
/// sirve para entender qué pasó ("¿por qué se saltó esa?", "¿fue con datos?")
/// y no tiene sentido sincronizarlo. Se queda con las [maxEntries] más
/// recientes.
class UnplayableTrackLog extends ChangeNotifier {
  UnplayableTrackLog(this._store) : _entries = _read(_store);

  static const storageKey = 'player.unplayable_log';
  static const maxEntries = 50;

  final AppSettingsStore _store;
  List<UnplayableEntry> _entries;

  /// La más reciente primero.
  List<UnplayableEntry> get entries => List.unmodifiable(_entries);

  void record(SyncoraTrack track, String reason, {DateTime? at}) {
    _entries = [
      UnplayableEntry(
        trackId: track.id,
        title: track.title,
        artist: track.artist,
        reason: reason,
        at: at ?? DateTime.now(),
      ),
      ..._entries,
    ].take(maxEntries).toList();
    _persist();
    notifyListeners();
  }

  void clear() {
    _entries = const [];
    _persist();
    notifyListeners();
  }

  void _persist() {
    _store.setString(storageKey, jsonEncode([for (final e in _entries) e.toJson()]));
  }

  static List<UnplayableEntry> _read(AppSettingsStore store) {
    final raw = store.getString(storageKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [
        for (final item in list) ?UnplayableEntry.fromJson(item),
      ];
    } catch (_) {
      return const [];
    }
  }
}

final unplayableTrackLogProvider = ChangeNotifierProvider<UnplayableTrackLog>(
  (ref) => UnplayableTrackLog(ref.watch(appSettingsStoreProvider)),
);
