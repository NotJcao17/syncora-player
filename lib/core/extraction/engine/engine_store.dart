import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'engine_bundle.dart';

/// Estado persistente del OTA del motor (Fase 8).
///
/// Regla de oro: el motor **activo** solo cambia cuando hay una prueba real
/// de que el nuevo funciona (una extracción exitosa durante una recuperación)
/// o cuando el manifiesto pide "aplicar a todos" (`adoptOnNextLaunch`).
/// Probar candidatos durante una emergencia no toca este estado.
@immutable
class EngineStoreState {
  /// Motores descargados y verificados que están en disco.
  final Map<int, EngineInfo> installed;

  /// Motor descargado en uso. `null` = el de fábrica.
  final int? activeBuild;

  /// Builds que ya extrajeron con éxito al menos una vez en este aparato.
  final Set<int> proven;

  /// Builds que no se vuelven a usar ni a descargar: no cargaron, fallaron
  /// con errores de código o fueron revocados por el manifiesto.
  final Set<int> blacklist;

  /// Build a activar en el siguiente arranque (rollout `next_launch`).
  final int? adoptOnNextLaunch;

  final DateTime? lastCheckAt;
  final DateTime? lastSuccessfulCheckAt;

  const EngineStoreState({
    this.installed = const {},
    this.activeBuild,
    this.proven = const {},
    this.blacklist = const {},
    this.adoptOnNextLaunch,
    this.lastCheckAt,
    this.lastSuccessfulCheckAt,
  });

  static const _keep = Object();

  EngineStoreState copyWith({
    Map<int, EngineInfo>? installed,
    Object? activeBuild = _keep,
    Set<int>? proven,
    Set<int>? blacklist,
    Object? adoptOnNextLaunch = _keep,
    DateTime? lastCheckAt,
    DateTime? lastSuccessfulCheckAt,
  }) =>
      EngineStoreState(
        installed: installed ?? this.installed,
        activeBuild: identical(activeBuild, _keep) ? this.activeBuild : activeBuild as int?,
        proven: proven ?? this.proven,
        blacklist: blacklist ?? this.blacklist,
        adoptOnNextLaunch:
            identical(adoptOnNextLaunch, _keep) ? this.adoptOnNextLaunch : adoptOnNextLaunch as int?,
        lastCheckAt: lastCheckAt ?? this.lastCheckAt,
        lastSuccessfulCheckAt: lastSuccessfulCheckAt ?? this.lastSuccessfulCheckAt,
      );

  Map<String, dynamic> toJson() => {
        'installed': [for (final e in installed.values) e.toJson()],
        'activeBuild': activeBuild,
        'proven': proven.toList(),
        'blacklist': blacklist.toList(),
        'adoptOnNextLaunch': adoptOnNextLaunch,
        'lastCheckAt': lastCheckAt?.toIso8601String(),
        'lastSuccessfulCheckAt': lastSuccessfulCheckAt?.toIso8601String(),
      };

  factory EngineStoreState.fromJson(Map<String, dynamic> json) {
    final installed = <int, EngineInfo>{};
    for (final raw in (json['installed'] as List? ?? const [])) {
      final info = EngineInfo.fromJson(Map<String, dynamic>.from(raw as Map));
      installed[info.build] = info;
    }
    Set<int> ints(Object? v) => {for (final x in (v as List? ?? const [])) (x as num).toInt()};
    DateTime? date(Object? v) => v is String ? DateTime.tryParse(v) : null;
    return EngineStoreState(
      installed: installed,
      activeBuild: (json['activeBuild'] as num?)?.toInt(),
      proven: ints(json['proven']),
      blacklist: ints(json['blacklist']),
      adoptOnNextLaunch: (json['adoptOnNextLaunch'] as num?)?.toInt(),
      lastCheckAt: date(json['lastCheckAt']),
      lastSuccessfulCheckAt: date(json['lastSuccessfulCheckAt']),
    );
  }

  /// ¿Se puede cargar este motor descargado?
  bool isUsable(int build) {
    final info = installed[build];
    return info != null && info.api == kSupportedEngineApi && !blacklist.contains(build);
  }

  /// Build más nuevo que ya tenemos (descargado o de fábrica).
  int newestKnownBuild(int embeddedBuild) {
    var best = embeddedBuild;
    for (final b in installed.keys) {
      if (b > best) best = b;
    }
    return best;
  }
}

/// Decisiones puras sobre [EngineStoreState]: qué motor arrancar, qué probar
/// en una emergencia, qué descargar. Sin E/S para poder testearlas.
class EnginePolicy {
  const EnginePolicy._();

  /// Motor descargado con el que arrancar (`null` = el de fábrica) y el
  /// estado resultante (consume `adoptOnNextLaunch`).
  ///
  /// Un motor de fábrica igual o más nuevo que el descargado gana siempre:
  /// así una actualización de la app nunca queda tapada por un OTA viejo.
  static (int?, EngineStoreState) selectForLaunch(EngineStoreState s, int embeddedBuild) {
    var state = s;
    final adopt = state.adoptOnNextLaunch;
    if (adopt != null) {
      state = state.copyWith(
        adoptOnNextLaunch: null,
        activeBuild: state.isUsable(adopt) ? adopt : state.activeBuild,
      );
    }
    final active = state.activeBuild;
    if (active != null && state.isUsable(active) && active > embeddedBuild) {
      return (active, state);
    }
    if (active != null) state = state.copyWith(activeBuild: null);
    return (null, state);
  }

  /// Orden en que probar otros motores cuando el actual ([currentBuild]) está
  /// roto: primero los más nuevos (lo normal es que el arreglo sea una
  /// versión posterior), después los anteriores, por si el roto es justo el
  /// nuevo. El de fábrica se representa con su propio build.
  static List<int> recoveryCandidates(
    EngineStoreState s, {
    required int embeddedBuild,
    required int currentBuild,
    Set<int> alreadyTried = const {},
  }) {
    final all = <int>{
      for (final b in s.installed.keys)
        if (s.isUsable(b)) b,
      embeddedBuild,
    }..removeAll({currentBuild, ...alreadyTried});
    final newer = all.where((b) => b > currentBuild).toList()..sort((a, b) => b - a);
    final older = all.where((b) => b < currentBuild).toList()..sort((a, b) => b - a);
    return [...newer, ...older];
  }

  /// ¿Vale la pena bajar este motor anunciado?
  static bool shouldDownload(
    EngineStoreState s, {
    required int embeddedBuild,
    required int build,
    required int api,
    required Set<int> revoked,
  }) {
    if (api != kSupportedEngineApi) return false;
    if (s.blacklist.contains(build) || revoked.contains(build)) return false;
    if (s.installed.containsKey(build)) return false;
    return build > s.newestKnownBuild(embeddedBuild);
  }

  /// Builds descargados que sobran: se conservan el activo, el pendiente de
  /// adoptar y los [keepNewest] más nuevos usables.
  static Set<int> buildsToPrune(EngineStoreState s, {int keepNewest = 2}) {
    final keep = <int>{
      if (s.activeBuild != null) s.activeBuild!,
      if (s.adoptOnNextLaunch != null) s.adoptOnNextLaunch!,
    };
    final usable = s.installed.keys.where(s.isUsable).toList()..sort((a, b) => b - a);
    keep.addAll(usable.take(keepNewest));
    return s.installed.keys.where((b) => !keep.contains(b)).toSet();
  }
}

/// Persistencia del OTA: `state.json` + un `engine-<build>.js` por motor, en
/// el directorio de soporte de la app (no visible para el usuario).
class EngineStore {
  final Directory dir;
  EngineStoreState _state;

  EngineStore._(this.dir, this._state);

  EngineStoreState get state => _state;

  static Future<EngineStore> open({Directory? directory}) async {
    final dir = directory ?? Directory(p.join((await getApplicationSupportDirectory()).path, 'syncora_engine'));
    await dir.create(recursive: true);
    var state = const EngineStoreState();
    final file = File(p.join(dir.path, 'state.json'));
    try {
      if (await file.exists()) {
        state = EngineStoreState.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
      }
    } catch (e) {
      // Un state.json corrupto no puede dejar a la app sin motor: se empieza
      // de cero y se usa el de fábrica.
      debugPrint('[EngineStore] state.json ilegible, se reinicia: $e');
    }
    // Quita del estado los motores cuyo archivo ya no existe.
    final missing = <int>[
      for (final b in state.installed.keys)
        if (!await File(p.join(dir.path, 'engine-$b.js')).exists()) b,
    ];
    if (missing.isNotEmpty) {
      state = state.copyWith(
        installed: Map.of(state.installed)..removeWhere((b, _) => missing.contains(b)),
      );
    }
    return EngineStore._(dir, state);
  }

  File _engineFile(int build) => File(p.join(dir.path, 'engine-$build.js'));

  Future<void> update(EngineStoreState next) async {
    _state = next;
    final file = File(p.join(dir.path, 'state.json'));
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(next.toJson()), flush: true);
    await tmp.rename(file.path);
  }

  /// Lee un motor descargado y comprueba que el archivo sigue siendo el que
  /// se verificó al instalarlo. Si no, lo descarta (y lo pone en lista negra
  /// para no volver a intentar con esa copia).
  Future<EngineBundle?> loadDownloaded(int build) async {
    final info = _state.installed[build];
    if (info == null) return null;
    try {
      final bytes = await _engineFile(build).readAsBytes();
      if (bytes.length != info.size || engineSha256(bytes) != info.sha256) {
        debugPrint('[EngineStore] Motor $build alterado o corrupto en disco: se descarta.');
        await _remove({build});
        return null;
      }
      return EngineBundle(code: utf8.decode(bytes), info: info, source: EngineSource.downloaded);
    } catch (e) {
      debugPrint('[EngineStore] No se pudo leer el motor $build: $e');
      return null;
    }
  }

  /// Guarda un motor ya verificado (firma del manifiesto + SHA-256 + tamaño).
  /// Escritura atómica: un corte a mitad nunca deja un motor a medias.
  Future<void> install(EngineInfo info, List<int> jsBytes) async {
    if (jsBytes.length != info.size || engineSha256(jsBytes) != info.sha256) {
      throw StateError('El motor ${info.build} no coincide con el manifiesto');
    }
    final target = _engineFile(info.build);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(jsBytes, flush: true);
    await tmp.rename(target.path);
    await update(_state.copyWith(installed: {..._state.installed, info.build: info}));
    await _remove(EnginePolicy.buildsToPrune(_state));
  }

  Future<void> _remove(Set<int> builds) async {
    if (builds.isEmpty) return;
    for (final b in builds) {
      try {
        final f = _engineFile(b);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    await update(_state.copyWith(
      installed: Map.of(_state.installed)..removeWhere((b, _) => builds.contains(b)),
      activeBuild: builds.contains(_state.activeBuild) ? null : _state.activeBuild,
    ));
  }

  Future<void> markProven(int build) async {
    if (_state.proven.contains(build)) return;
    await update(_state.copyWith(proven: {..._state.proven, build}));
  }

  Future<void> addToBlacklist(Set<int> builds) async {
    if (builds.isEmpty || _state.blacklist.containsAll(builds)) return;
    await update(_state.copyWith(
      blacklist: {..._state.blacklist, ...builds},
      activeBuild: builds.contains(_state.activeBuild) ? null : _state.activeBuild,
      adoptOnNextLaunch: builds.contains(_state.adoptOnNextLaunch) ? null : _state.adoptOnNextLaunch,
    ));
  }
}
