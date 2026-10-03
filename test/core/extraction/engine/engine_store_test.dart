import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:syncora_player/core/extraction/engine/engine_bundle.dart';
import 'package:syncora_player/core/extraction/engine/engine_store.dart';

import 'engine_test_utils.dart';

const _embedded = 202610010000;

EngineStoreState _withInstalled(List<int> builds, {int? active, Set<int> blacklist = const {}, int? adopt}) =>
    EngineStoreState(
      installed: {for (final b in builds) b: fakeEngine(b).info},
      activeBuild: active,
      blacklist: blacklist,
      adoptOnNextLaunch: adopt,
    );

void main() {
  group('EnginePolicy.selectForLaunch', () {
    test('sin nada descargado arranca el de fábrica', () {
      final (build, _) = EnginePolicy.selectForLaunch(const EngineStoreState(), _embedded);
      expect(build, isNull);
    });

    test('un motor descargado que no está activo NO se usa (solo se guarda)', () {
      final (build, _) = EnginePolicy.selectForLaunch(_withInstalled([202610020000]), _embedded);
      expect(build, isNull);
    });

    test('usa el activo descargado si es más nuevo que el de fábrica', () {
      final (build, _) = EnginePolicy.selectForLaunch(
        _withInstalled([202610020000], active: 202610020000),
        _embedded,
      );
      expect(build, 202610020000);
    });

    test('una app actualizada con motor de fábrica más nuevo gana al OTA viejo', () {
      final (build, next) = EnginePolicy.selectForLaunch(
        _withInstalled([202610020000], active: 202610020000),
        202610050000,
      );
      expect(build, isNull);
      expect(next.activeBuild, isNull);
    });

    test('un activo en lista negra no se usa', () {
      final (build, next) = EnginePolicy.selectForLaunch(
        _withInstalled([202610020000], active: 202610020000, blacklist: {202610020000}),
        _embedded,
      );
      expect(build, isNull);
      expect(next.activeBuild, isNull);
    });

    test('"aplicar a todos" se activa en el siguiente arranque y se consume', () {
      final (build, next) = EnginePolicy.selectForLaunch(
        _withInstalled([202610020000], adopt: 202610020000),
        _embedded,
      );
      expect(build, 202610020000);
      expect(next.activeBuild, 202610020000);
      expect(next.adoptOnNextLaunch, isNull);
    });
  });

  group('EnginePolicy.recoveryCandidates', () {
    test('primero los más nuevos, luego los anteriores, sin el actual ni los vetados', () {
      final s = _withInstalled(
        [202610020000, 202610030000, 202610040000, 202610050000],
        blacklist: {202610040000},
      );
      final order = EnginePolicy.recoveryCandidates(s, embeddedBuild: _embedded, currentBuild: 202610030000);
      expect(order, [202610050000, 202610020000, _embedded]);
    });

    test('sin nada descargado y con el de fábrica roto no hay candidatos', () {
      final order = EnginePolicy.recoveryCandidates(
        const EngineStoreState(),
        embeddedBuild: _embedded,
        currentBuild: _embedded,
      );
      expect(order, isEmpty);
    });
  });

  group('EnginePolicy.shouldDownload', () {
    test('solo baja lo más nuevo que todo lo que ya hay', () {
      final s = _withInstalled([202610030000]);
      bool should(int build, {int api = kSupportedEngineApi, Set<int> revoked = const {}}) =>
          EnginePolicy.shouldDownload(s, embeddedBuild: _embedded, build: build, api: api, revoked: revoked);

      expect(should(202610040000), isTrue);
      expect(should(202610030000), isFalse, reason: 'ya instalado');
      expect(should(202610020000), isFalse, reason: 'más viejo que lo instalado');
      expect(should(202609010000), isFalse, reason: 'más viejo que el de fábrica');
      expect(should(202610040000, api: kSupportedEngineApi + 1), isFalse, reason: 'api incompatible');
      expect(should(202610040000, revoked: {202610040000}), isFalse, reason: 'revocado');
    });
  });

  test('buildsToPrune conserva el activo, el pendiente y los 2 más nuevos', () {
    final s = _withInstalled(
      [202610020000, 202610030000, 202610040000, 202610050000, 202610060000],
      active: 202610020000,
    );
    expect(EnginePolicy.buildsToPrune(s), {202610030000, 202610040000});
  });

  group('EngineStore en disco', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('engine_store_test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('instala, persiste y vuelve a leer un motor verificado', () async {
      final e = fakeEngine(202610020000);
      final store = await EngineStore.open(directory: dir);
      await store.install(e.info, e.bytes);
      await store.markProven(e.info.build);

      final reopened = await EngineStore.open(directory: dir);
      expect(reopened.state.installed.keys, [202610020000]);
      expect(reopened.state.proven, {202610020000});
      final bundle = await reopened.loadDownloaded(202610020000);
      expect(bundle!.code, e.code);
      expect(bundle.source, EngineSource.downloaded);
    });

    test('se niega a instalar bytes que no coinciden con la ficha', () async {
      final e = fakeEngine(202610020000);
      final store = await EngineStore.open(directory: dir);
      await expectLater(store.install(e.info, [...e.bytes, 32]), throwsStateError);
      expect(store.state.installed, isEmpty);
    });

    test('descarta un motor alterado en disco en vez de ejecutarlo', () async {
      final e = fakeEngine(202610020000);
      final store = await EngineStore.open(directory: dir);
      await store.install(e.info, e.bytes);
      await File(p.join(dir.path, 'engine-202610020000.js')).writeAsString('globalThis.malo = 1;');

      expect(await store.loadDownloaded(202610020000), isNull);
      expect(store.state.installed, isEmpty);
    });

    test('un state.json corrupto no rompe nada: se empieza de cero', () async {
      await File(p.join(dir.path, 'state.json')).writeAsString('{esto no es json');
      final store = await EngineStore.open(directory: dir);
      expect(store.state.installed, isEmpty);
      expect(store.state.activeBuild, isNull);
    });

    test('vetar el activo lo desactiva', () async {
      final e = fakeEngine(202610020000);
      final store = await EngineStore.open(directory: dir);
      await store.install(e.info, e.bytes);
      await store.update(store.state.copyWith(activeBuild: 202610020000));
      await store.addToBlacklist({202610020000});
      expect(store.state.activeBuild, isNull);
      expect(store.state.isUsable(202610020000), isFalse);
    });
  });
}
