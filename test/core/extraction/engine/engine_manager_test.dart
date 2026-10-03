import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/extraction/engine/engine_bundle.dart';
import 'package:syncora_player/core/extraction/engine/engine_manager.dart';
import 'package:syncora_player/core/extraction/engine/engine_manifest.dart';
import 'package:syncora_player/core/extraction/engine/engine_store.dart';
import 'package:syncora_player/core/extraction/engine/engine_updater.dart';
import 'package:syncora_player/core/extraction/extraction_isolate.dart';
import 'package:syncora_player/core/extraction/models/extraction_request.dart';
import 'package:syncora_player/core/extraction/models/extraction_result.dart';

import 'engine_test_utils.dart';

const _embeddedBuild = 202610010000;

/// Isolate falso: "carga" el motor que le pasen y extrae según una tabla de
/// qué builds funcionan.
class _FakeIsolate extends ExtractionIsolate {
  final Set<int> working = {};
  final Set<int> failsToLoad = {};
  final List<int> loaded = [];
  int? _running;

  @override
  bool get isInitialized => _running != null;

  @override
  Future<EngineLoadReport> spawn(EngineBundle bundle) async {
    loaded.add(bundle.build);
    if (failsToLoad.contains(bundle.build)) {
      _running = bundle.build;
      return const EngineLoadReport(ok: false, error: 'El motor no compila');
    }
    _running = bundle.build;
    return EngineLoadReport(ok: true, build: bundle.build);
  }

  @override
  Future<EngineLoadReport> reload(EngineBundle bundle, {Duration drainTimeout = const Duration(seconds: 30)}) =>
      spawn(bundle);

  @override
  Future<ExtractionResult> request(ExtractionRequest request) async {
    if (working.contains(_running)) {
      return ExtractionSuccess(requestId: request.requestId, streamUrl: 'https://audio', headers: const {});
    }
    return ExtractionFailure(
      requestId: request.requestId,
      error: ExtractionError.notFound,
      message: 'Streaming data not available',
      suspectEngine: true,
    );
  }
}

class _FakeUpdater extends EngineUpdater {
  _FakeUpdater(this.signer) : super(publicKey: signer.publicKey);

  final TestSigner signer;
  String? manifestBody;
  final Map<int, List<int>> files = {};
  int manifestFetches = 0;

  @override
  Future<EngineManifest> fetchManifest() async {
    manifestFetches++;
    final body = manifestBody;
    if (body == null) throw const SocketException('sin red');
    return EngineManifest.verifyAndParse(body, publicKey: signer.publicKey);
  }

  @override
  Future<List<int>> download(EngineRelease release) async => files[release.build]!;

  Future<void> publish(List<int> builds, {String rollout = 'on_failure', List<int> revoked = const []}) async {
    final engines = [for (final b in builds) fakeEngine(b)];
    for (final e in engines) {
      files[e.info.build] = e.bytes;
    }
    manifestBody = await signer.sign(manifestPayload(
      [for (final e in engines) e.info],
      rollout: rollout,
      revoked: revoked,
    ));
  }
}

ExtractionRequest _req(String id) => ExtractionRequest(videoId: id, requestId: 'req_$id', trackTitle: 't', trackArtist: 'a');

ExtractionFailure _suspect(String id) => ExtractionFailure(
      requestId: 'req_$id',
      error: ExtractionError.notFound,
      message: 'Streaming data not available',
      suspectEngine: true,
    );

void main() {
  late Directory dir;
  late TestSigner signer;
  late _FakeIsolate isolate;
  late _FakeUpdater updater;
  late DateTime now;

  EngineManager build() => EngineManager(
        isolate: isolate,
        updater: updater,
        openStore: () => EngineStore.open(directory: dir),
        loadEmbedded: () async => embeddedBundle(_embeddedBuild),
        otaConfigured: true,
        clock: () => now,
      );

  setUpAll(() async {
    signer = await TestSigner.create();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('engine_manager_test');
    isolate = _FakeIsolate();
    updater = _FakeUpdater(signer);
    now = DateTime(2026, 10, 2, 12);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('una actualización se descarga y se guarda, pero NO reemplaza al motor que funciona', () async {
    await updater.publish([202610020000]);
    final m = build();
    await m.ensureEngine();

    final result = await m.checkForUpdates();
    expect(result.outcome, EngineCheckOutcome.downloaded);
    expect(m.current!.build, _embeddedBuild);
    expect(m.status.value.standbyBuild, 202610020000);

    // Tras reiniciar sigue arrancando el de fábrica.
    final store = await EngineStore.open(directory: dir);
    expect(store.state.activeBuild, isNull);
    expect(store.state.installed.keys, [202610020000]);
  });

  test('la comprobación normal se limita a una cada 12 h; la forzada no', () async {
    await updater.publish([202610020000]);
    final m = build();
    await m.checkForUpdates();
    expect((await m.checkForUpdates()).outcome, EngineCheckOutcome.throttled);
    expect((await m.checkForUpdates(force: true)).outcome, EngineCheckOutcome.upToDate);
    now = now.add(const Duration(hours: 13));
    expect((await m.checkForUpdates()).outcome, EngineCheckOutcome.upToDate);
    expect(updater.manifestFetches, 3);
  });

  test('motor roto: se pasa al descargado, se reintenta y queda activo', () async {
    await updater.publish([202610020000]);
    isolate.working.add(202610020000); // el de fábrica no funciona
    final m = build();
    await m.ensureEngine();
    final event = m.events.first.timeout(const Duration(seconds: 10));

    expect(m.process(_req('a'), _suspect('a')), isA<ExtractionFailure>());
    final second = m.process(_req('b'), _suspect('b')) as ExtractionFailure;
    expect(second.error, ExtractionError.engineBroken);

    expect(await event, EngineEvent.recovered);
    expect(m.current!.build, 202610020000);
    expect(m.status.value.health, EngineHealth.ok);

    final store = await EngineStore.open(directory: dir);
    expect(store.state.activeBuild, 202610020000, reason: 'probado: se usará en los siguientes arranques');
    expect(store.state.proven, contains(202610020000));
  });

  test('motor roto sin ningún arreglo disponible: avisa y vuelve al motor original', () async {
    final m = build();
    await m.ensureEngine();
    final event = m.events.first.timeout(const Duration(seconds: 10));

    m.process(_req('a'), _suspect('a'));
    m.process(_req('b'), _suspect('b'));

    expect(await event, EngineEvent.noFix);
    expect(m.current!.build, _embeddedBuild);
    expect(m.status.value.health, EngineHealth.noFix);
  });

  test('si el candidato tampoco extrae, se vuelve al original y no se activa', () async {
    await updater.publish([202610020000]);
    final m = build();
    await m.ensureEngine();
    final event = m.events.first.timeout(const Duration(seconds: 10));

    m.process(_req('a'), _suspect('a'));
    m.process(_req('b'), _suspect('b'));

    expect(await event, EngineEvent.noFix);
    expect(m.current!.build, _embeddedBuild);
    final store = await EngineStore.open(directory: dir);
    expect(store.state.activeBuild, isNull);
  });

  test('un motor descargado que no carga al arrancar se veta y se usa el de fábrica', () async {
    final e = fakeEngine(202610020000);
    final store = await EngineStore.open(directory: dir);
    await store.install(e.info, e.bytes);
    await store.update(store.state.copyWith(activeBuild: 202610020000));
    isolate.failsToLoad.add(202610020000);

    final m = build();
    await m.ensureEngine();

    expect(isolate.loaded, [202610020000, _embeddedBuild]);
    expect(m.current!.build, _embeddedBuild);
    final reopened = await EngineStore.open(directory: dir);
    expect(reopened.state.blacklist, contains(202610020000));
    expect(reopened.state.activeBuild, isNull);
  });

  test('"aplicar a todos" deja el motor listo para el siguiente arranque', () async {
    await updater.publish([202610020000], rollout: 'next_launch');
    final m = build();
    await m.checkForUpdates();
    expect(m.status.value.adoptOnNextLaunch, 202610020000);

    final next = EngineManager(
      isolate: _FakeIsolate(),
      updater: updater,
      openStore: () => EngineStore.open(directory: dir),
      loadEmbedded: () async => embeddedBundle(_embeddedBuild),
      otaConfigured: true,
      clock: () => now,
    );
    await next.ensureEngine();
    expect(next.current!.build, 202610020000);
  });

  test('un motor revocado se veta y deja de usarse', () async {
    final e = fakeEngine(202610020000);
    final store = await EngineStore.open(directory: dir);
    await store.install(e.info, e.bytes);
    await store.update(store.state.copyWith(activeBuild: 202610020000));

    final m = build();
    await m.ensureEngine();
    expect(m.current!.build, 202610020000);

    await updater.publish([202610030000], revoked: [202610020000]);
    await m.checkForUpdates(force: true);

    expect(m.current!.build, _embeddedBuild);
    final reopened = await EngineStore.open(directory: dir);
    expect(reopened.state.blacklist, contains(202610020000));
  });

  test('sin red la comprobación falla en silencio y no toca nada', () async {
    final m = build();
    await m.ensureEngine();
    final result = await m.checkForUpdates();
    expect(result.outcome, EngineCheckOutcome.failed);
    expect(m.current!.build, _embeddedBuild);
  });

  test('sin llave configurada el OTA queda desactivado', () async {
    final m = EngineManager(
      isolate: isolate,
      updater: updater,
      openStore: () => EngineStore.open(directory: dir),
      loadEmbedded: () async => embeddedBundle(_embeddedBuild),
      otaConfigured: false,
    );
    expect((await m.checkForUpdates(force: true)).outcome, EngineCheckOutcome.disabled);
    expect(updater.manifestFetches, 0);
  });

  test('los fallos que no son del motor pasan tal cual', () async {
    final m = build();
    await m.ensureEngine();
    final network = ExtractionFailure(requestId: 'x', error: ExtractionError.networkError);
    expect(identical(m.process(_req('a'), network), network), isTrue);
    final notFound = ExtractionFailure(requestId: 'y', error: ExtractionError.notFound);
    expect(identical(m.process(_req('b'), notFound), notFound), isTrue);
    expect(identical(m.process(_req('c'), notFound), notFound), isTrue);
  });
}
