import 'dart:async';

import 'package:flutter/foundation.dart';

import '../extraction_isolate.dart';
import '../js_bundle_loader.dart';
import '../models/extraction_request.dart';
import '../models/extraction_result.dart';
import 'engine_bundle.dart';
import 'engine_health_monitor.dart';
import 'engine_manifest.dart';
import 'engine_store.dart';
import 'engine_trust.dart';
import 'engine_updater.dart';

enum EngineHealth {
  /// Funciona (o todavía no hay evidencia de lo contrario).
  ok,

  /// Declarado roto; todavía no se intentó recuperar.
  broken,

  /// Buscando actualización y probando otros motores.
  recovering,

  /// Se probó todo y ninguno funciona: falta un arreglo publicado.
  noFix,
}

/// Lo que la app sabe del motor en este momento (Configuración lo muestra).
@immutable
class EngineStatus {
  final EngineInfo? info;
  final EngineSource? source;
  final EngineHealth health;
  final String? loadError;
  final bool otaConfigured;
  final DateTime? lastCheckAt;

  /// Cuándo se activó por OTA el motor en uso (`null` si es el de fábrica).
  final DateTime? activatedAt;

  /// Motor descargado más nuevo que el activo, guardado "por si falla".
  final int? standbyBuild;

  /// Motor que se activará en el siguiente arranque, si lo hay.
  final int? adoptOnNextLaunch;

  const EngineStatus({
    this.info,
    this.source,
    this.health = EngineHealth.ok,
    this.loadError,
    this.otaConfigured = false,
    this.lastCheckAt,
    this.activatedAt,
    this.standbyBuild,
    this.adoptOnNextLaunch,
  });
}

enum EngineEvent {
  /// Un motor distinto volvió a extraer: el reproductor puede reintentar.
  recovered,

  /// Se probó todo sin éxito.
  noFix,
}

enum EngineCheckOutcome { disabled, throttled, upToDate, downloaded, failed }

@immutable
class EngineCheckResult {
  final EngineCheckOutcome outcome;
  final int? build;
  final String? message;
  const EngineCheckResult(this.outcome, {this.build, this.message});
}

/// Orquesta el motor de extracción (Fase 8): con qué motor arrancar, cuándo
/// declararlo roto, cómo recuperarse y cuándo buscar actualizaciones.
///
/// Diseño completo en `docs/fases/fase_8.md`. Las dos reglas que no se deben
/// romper: **un motor que funciona no se cambia solo** (lo descargado espera
/// guardado hasta que el activo falle, salvo "aplicar a todos"), y **el motor
/// activo persistido solo cambia con prueba** (una extracción real exitosa).
class EngineManager {
  EngineManager({
    required ExtractionIsolate isolate,
    EngineUpdater? updater,
    Future<EngineStore> Function()? openStore,
    Future<EngineBundle> Function()? loadEmbedded,
    bool? otaConfigured,
    DateTime Function()? clock,
  })  : _isolate = isolate, // ignore: prefer_initializing_formals
        _updater = updater ?? EngineUpdater(),
        _openStore = openStore ?? EngineStore.open,
        _loadEmbedded = loadEmbedded ?? JsBundleLoader.loadEmbedded,
        _otaConfigured = otaConfigured ?? isEngineOtaConfigured,
        _clock = clock ?? DateTime.now;

  final ExtractionIsolate _isolate;
  final EngineUpdater _updater;
  final Future<EngineStore> Function() _openStore;
  final Future<EngineBundle> Function() _loadEmbedded;
  final bool _otaConfigured;
  final DateTime Function() _clock;

  static const Duration normalCheckInterval = Duration(hours: 12);
  static const Duration emergencyCheckInterval = Duration(minutes: 30);
  static const Duration recoveryCooldown = Duration(minutes: 10);
  static const Duration startupCheckDelay = Duration(seconds: 15);

  final EngineHealthMonitor _monitor = EngineHealthMonitor();
  late final ValueNotifier<EngineStatus> status = ValueNotifier(EngineStatus(otaConfigured: _otaConfigured));
  final StreamController<EngineEvent> _events = StreamController.broadcast();
  Stream<EngineEvent> get events => _events.stream;

  EngineBundle? _embedded;
  EngineStore? _store;
  bool _storeUnavailable = false;
  EngineBundle? _current;
  String? _loadError;
  EngineHealth _health = EngineHealth.ok;

  Future<void>? _ensuring;
  Future<void>? _recovering;
  Future<EngineCheckResult>? _checking;
  ExtractionRequest? _lastFailedRequest;
  DateTime? _lastRecoveryAt;
  DateTime? _lastEmergencyCheckAt;
  bool _newCandidatesSinceRecovery = false;
  Timer? _startupTimer;
  Timer? _periodicTimer;
  bool _disposed = false;

  EngineBundle? get current => _current;

  // ---------------------------------------------------------------------------
  // Arranque
  // ---------------------------------------------------------------------------

  Future<EngineBundle> _embeddedBundle() async => _embedded ??= await _loadEmbedded();

  Future<EngineStore?> _storeOrNull() async {
    if (_store != null || _storeUnavailable) return _store;
    try {
      _store = await _openStore();
    } catch (e) {
      // Sin almacenamiento el OTA no funciona, pero la app sí: motor de fábrica.
      debugPrint('[EngineManager] Almacén del motor no disponible: $e');
      _storeUnavailable = true;
    }
    return _store;
  }

  /// Motor con el que arrancar: el descargado activo si es válido y más nuevo
  /// que el de fábrica; si no, el de fábrica.
  Future<EngineBundle> _launchBundle() async {
    final embedded = await _embeddedBundle();
    final store = await _storeOrNull();
    if (store == null) return embedded;
    final (build, next) = EnginePolicy.selectForLaunch(store.state, embedded.build, now: _clock());
    if (!identical(next, store.state)) await store.update(next);
    if (build == null) return embedded;
    return await store.loadDownloaded(build) ?? embedded;
  }

  /// Garantiza que el isolate esté corriendo con un motor. Si un motor
  /// descargado no carga, se pone en lista negra y se vuelve al de fábrica.
  Future<void> ensureEngine() {
    if (_isolate.isInitialized && _current != null) return Future.value();
    // Durante una recuperación el isolate se recarga varias veces; las
    // peticiones esperan solas en la compuerta de `ExtractionIsolate.reload`.
    if (_recovering != null) return Future.value();
    return _ensuring ??= _ensure().whenComplete(() => _ensuring = null);
  }

  Future<void> _ensure() async {
    var bundle = _current ?? await _launchBundle();
    var report = await _isolate.spawn(bundle);
    if (!report.ok && bundle.source == EngineSource.downloaded) {
      debugPrint('[EngineManager] El motor ${bundle.build} no cargó (${report.error}); vuelvo al de fábrica.');
      await (await _storeOrNull())?.addToBlacklist({bundle.build});
      bundle = await _embeddedBundle();
      report = await _isolate.reload(bundle);
    }
    _current = bundle;
    _loadError = report.ok ? null : report.error;
    if (!report.ok) {
      _monitor.markLoadFailure();
      _health = EngineHealth.broken;
      unawaited(_recover());
    }
    await _publishStatus();
  }

  // ---------------------------------------------------------------------------
  // Resultados de extracción
  // ---------------------------------------------------------------------------

  /// Pasa cada resultado por el monitor. Si con este fallo el motor queda
  /// roto, lo convierte en [ExtractionError.engineBroken] y arranca la
  /// recuperación en segundo plano.
  ExtractionResult process(ExtractionRequest request, ExtractionResult result) {
    switch (result) {
      case ExtractionSuccess():
        final wasUnhealthy = _health != EngineHealth.ok;
        _monitor.recordSuccess();
        _health = EngineHealth.ok;
        final build = _current?.build;
        if (_current?.source == EngineSource.downloaded && build != null) {
          unawaited(_store?.markProven(build));
        }
        if (wasUnhealthy) unawaited(_publishStatus());
        return result;
      case ExtractionFailure(:final error):
        if (error == ExtractionError.cancelled) return result;
        final broken = _monitor.recordFailure(request.videoId, result);
        if (!broken) return result;
        _lastFailedRequest = request;
        if (_health == EngineHealth.ok) _health = EngineHealth.broken;
        unawaited(_recover());
        unawaited(_publishStatus());
        return ExtractionFailure(
          requestId: result.requestId,
          error: ExtractionError.engineBroken,
          message: result.message,
          suspectEngine: true,
        );
    }
  }

  // ---------------------------------------------------------------------------
  // Recuperación
  // ---------------------------------------------------------------------------

  Future<void> _recover() => _recovering ??= _runRecovery().whenComplete(() => _recovering = null);

  Future<void> _runRecovery() async {
    final now = _clock();
    final last = _lastRecoveryAt;
    if (last != null && now.difference(last) < recoveryCooldown && !_newCandidatesSinceRecovery) {
      _finishWithoutFix();
      return;
    }
    _lastRecoveryAt = now;
    _newCandidatesSinceRecovery = false;
    _health = EngineHealth.recovering;
    await _publishStatus();

    await checkForUpdates(emergency: true);

    final embedded = await _embeddedBundle();
    final store = await _storeOrNull();
    final original = _current ?? embedded;
    final candidates = EnginePolicy.recoveryCandidates(
      store?.state ?? const EngineStoreState(),
      embeddedBuild: embedded.build,
      currentBuild: original.build,
    );
    debugPrint('[EngineManager] Motor ${original.build} roto. Candidatos: $candidates');

    for (final build in candidates) {
      if (_disposed) return;
      final bundle = build == embedded.build ? embedded : await store?.loadDownloaded(build);
      if (bundle == null) continue;
      final report = await _isolate.reload(bundle);
      _current = bundle;
      if (!report.ok) {
        if (bundle.source == EngineSource.downloaded) await store?.addToBlacklist({build});
        continue;
      }
      final probe = _lastFailedRequest;
      final ExtractionResult? result = probe == null
          ? null
          : await _isolate.request(ExtractionRequest(
              videoId: probe.videoId,
              requestId: 'engine_probe_${_clock().microsecondsSinceEpoch}',
              priority: probe.priority,
              trackTitle: probe.trackTitle,
              trackArtist: probe.trackArtist,
              durationSeconds: probe.durationSeconds,
              quality: probe.quality,
            ));
      if (result == null || result is ExtractionSuccess) {
        debugPrint('[EngineManager] El motor $build funciona: queda activo.');
        if (store != null) {
          await store.update(store.state.copyWith(
            activeBuild: bundle.source == EngineSource.downloaded ? build : null,
            activatedAt: _clock(),
          ));
          if (bundle.source == EngineSource.downloaded) await store.markProven(build);
        }
        _monitor.recordSuccess();
        _loadError = null;
        _health = EngineHealth.ok;
        await _publishStatus();
        _events.add(EngineEvent.recovered);
        return;
      }
      if (result is ExtractionFailure &&
          bundle.source == EngineSource.downloaded &&
          EngineHealthMonitor.isCodeError(result.message)) {
        // Falla con errores de su propio código: no se vuelve a probar.
        await store?.addToBlacklist({build});
      }
    }

    // Nada funcionó: se vuelve al motor con el que se estaba.
    if (!identical(_current, original)) {
      final report = await _isolate.reload(original);
      _current = original;
      _loadError = report.ok ? null : report.error;
    }
    _finishWithoutFix();
  }

  void _finishWithoutFix() {
    _health = EngineHealth.noFix;
    unawaited(_publishStatus());
    if (!_events.isClosed) _events.add(EngineEvent.noFix);
  }

  // ---------------------------------------------------------------------------
  // Actualizaciones
  // ---------------------------------------------------------------------------

  /// Revisa el manifiesto y baja el motor nuevo si lo hay. Nunca lo activa:
  /// queda guardado para cuando el actual falle (o para el próximo arranque,
  /// si el manifiesto dice "aplicar a todos").
  Future<EngineCheckResult> checkForUpdates({bool emergency = false, bool force = false}) {
    final inFlight = _checking;
    if (inFlight != null) return inFlight;
    final run = _check(emergency: emergency, force: force);
    _checking = run;
    return run.whenComplete(() => _checking = null);
  }

  Future<EngineCheckResult> _check({required bool emergency, required bool force}) async {
    if (!_otaConfigured) return const EngineCheckResult(EngineCheckOutcome.disabled);
    final store = await _storeOrNull();
    if (store == null) {
      return const EngineCheckResult(EngineCheckOutcome.failed, message: 'Almacenamiento no disponible');
    }
    final now = _clock();
    if (!force) {
      if (emergency) {
        final last = _lastEmergencyCheckAt;
        if (last != null && now.difference(last) < emergencyCheckInterval) {
          return const EngineCheckResult(EngineCheckOutcome.throttled);
        }
      } else {
        final last = store.state.lastCheckAt;
        if (last != null && now.difference(last) < normalCheckInterval) {
          return const EngineCheckResult(EngineCheckOutcome.throttled);
        }
      }
    }
    if (emergency) _lastEmergencyCheckAt = now;
    await store.update(store.state.copyWith(lastCheckAt: now));

    try {
      final manifest = await _updater.fetchManifest();
      await store.update(store.state.copyWith(lastSuccessfulCheckAt: now));
      await _applyRevocations(store, manifest);

      final embedded = await _embeddedBundle();
      final release = manifest.latestFor(kSupportedEngineApi);
      if (release == null) return const EngineCheckResult(EngineCheckOutcome.upToDate);

      if (EnginePolicy.shouldDownload(
        store.state,
        embeddedBuild: embedded.build,
        build: release.build,
        api: release.api,
        revoked: manifest.revoked,
      )) {
        final bytes = await _updater.download(release);
        await store.install(release.info, bytes);
        _newCandidatesSinceRecovery = true;
        if (release.rollout == EngineRollout.nextLaunch) {
          await store.update(store.state.copyWith(adoptOnNextLaunch: release.build));
        }
        debugPrint('[EngineManager] Motor ${release.build} descargado y guardado.');
        return EngineCheckResult(EngineCheckOutcome.downloaded, build: release.build);
      }

      // Ya lo teníamos guardado "por si falla" y ahora piden aplicarlo a todos.
      if (release.rollout == EngineRollout.nextLaunch &&
          store.state.isUsable(release.build) &&
          store.state.activeBuild != release.build &&
          (_current?.build ?? 0) != release.build) {
        await store.update(store.state.copyWith(adoptOnNextLaunch: release.build));
      }
      return const EngineCheckResult(EngineCheckOutcome.upToDate);
    } catch (e) {
      debugPrint('[EngineManager] Comprobación de motor fallida: $e');
      return EngineCheckResult(EngineCheckOutcome.failed, message: e.toString());
    } finally {
      await _publishStatus();
    }
  }

  /// Un motor revocado por el manifiesto no se vuelve a usar. Si es el que
  /// está corriendo, se cambia por el de arranque en cuanto no haya
  /// extracciones en curso.
  Future<void> _applyRevocations(EngineStore store, EngineManifest manifest) async {
    final revokedInstalled = manifest.revoked.where(store.state.installed.containsKey).toSet();
    if (revokedInstalled.isEmpty) return;
    await store.addToBlacklist(revokedInstalled);
    final running = _current;
    if (running != null &&
        running.source == EngineSource.downloaded &&
        revokedInstalled.contains(running.build)) {
      debugPrint('[EngineManager] El motor en uso (${running.build}) fue revocado.');
      final replacement = await _launchBundle();
      final report = await _isolate.reload(replacement);
      _current = replacement;
      _loadError = report.ok ? null : report.error;
    }
  }

  /// "Usar en el próximo arranque" desde Configuración.
  Future<void> adoptOnNextLaunch(int build) async {
    final store = await _storeOrNull();
    if (store == null || !store.state.isUsable(build)) return;
    await store.update(store.state.copyWith(adoptOnNextLaunch: build));
    await _publishStatus();
  }

  /// Comprobación 15 s después de arrancar y luego cada 6 h (el propio
  /// [checkForUpdates] la limita a una cada 12 h).
  void scheduleBackgroundChecks() {
    if (!_otaConfigured) {
      unawaited(_publishStatus());
      return;
    }
    _startupTimer?.cancel();
    _startupTimer = Timer(startupCheckDelay, () => checkForUpdates());
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(const Duration(hours: 6), (_) => checkForUpdates());
  }

  Future<void> _publishStatus() async {
    if (_disposed) return;
    final store = await _storeOrNull();
    final state = store?.state;
    final currentBuild = _current?.build ?? _embedded?.build ?? 0;
    int? standby;
    if (state != null) {
      for (final b in state.installed.keys) {
        if (state.isUsable(b) && b > currentBuild && (standby == null || b > standby)) standby = b;
      }
    }
    if (_disposed) return;
    status.value = EngineStatus(
      info: _current?.info ?? _embedded?.info,
      source: _current?.source ?? (_embedded != null ? EngineSource.embedded : null),
      health: _health,
      loadError: _loadError,
      otaConfigured: _otaConfigured,
      lastCheckAt: state?.lastCheckAt,
      activatedAt: _current?.source == EngineSource.downloaded ? state?.activatedAt : null,
      standbyBuild: standby,
      adoptOnNextLaunch: state?.adoptOnNextLaunch,
    );
  }

  /// Para Configuración: carga la ficha del motor sin arrancar el isolate.
  Future<void> refreshStatus() async {
    await _embeddedBundle();
    await _publishStatus();
  }

  void dispose() {
    _disposed = true;
    _startupTimer?.cancel();
    _periodicTimer?.cancel();
    _events.close();
    status.dispose();
  }
}
