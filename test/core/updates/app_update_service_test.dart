import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syncora_player/core/settings/app_settings_store.dart';
import 'package:syncora_player/core/updates/app_update.dart';
import 'package:syncora_player/core/updates/app_update_service.dart';

void main() {
  late Directory tmp;
  late AppSettingsStore settings;
  final payload = List<int>.generate(300000, (i) => i % 251);
  final payloadHash = sha256.convert(payload).toString();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('syncora_update_test');
    settings = AppSettingsStore.inMemory();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Map<String, dynamic> releaseJson({String tag = 'v1.4.0', String? digest}) => {
        'tag_name': tag,
        'draft': false,
        'prerelease': false,
        'html_url': 'https://github.com/x/releases/tag/$tag',
        'body': '',
        'assets': [
          {
            'name': 'Syncora.apk',
            'size': payload.length,
            'digest': 'sha256:${digest ?? payloadHash}',
            'browser_download_url': 'https://github.com/x/releases/download/$tag/Syncora.apk',
          },
        ],
      };

  AppUpdateService service({
    required http.Client client,
    DateTime Function()? clock,
  }) =>
      AppUpdateService(
        platform: UpdatePlatform.android,
        settings: settings,
        client: client,
        currentVersion: () async => '1.3.0',
        downloadDir: () async => Directory('${tmp.path}/updates'),
        clock: clock,
      );

  http.Client apiClient(Map<String, dynamic> json, {void Function()? onCall}) => MockClient((req) async {
        onCall?.call();
        return http.Response(jsonEncode(json), 200);
      });

  group('consulta', () {
    test('encuentra la versión nueva y anota la hora de la consulta', () async {
      final now = DateTime(2026, 11, 22, 12);
      final s = service(client: apiClient(releaseJson()), clock: () => now);
      final update = await s.check();
      expect(update!.version.toString(), '1.4.0');
      expect(settings.getInt(AppUpdateService.lastCheckKey), now.millisecondsSinceEpoch);
    });

    test('un error de GitHub lanza en la consulta manual y se calla al abrir la app', () async {
      final client = MockClient((_) async => http.Response('rate limited', 403));
      final s = service(client: client);
      await expectLater(s.check(), throwsA(isA<HttpException>()));
      expect(await s.checkOnStartup(), isNull);
      // Un fallo no cuenta como consulta: se reintenta al próximo arranque.
      expect(settings.getInt(AppUpdateService.lastCheckKey), isNull);
    });

    test('al abrir la app consulta como mucho cada 12 h', () async {
      var calls = 0;
      var now = DateTime(2026, 11, 22, 8);
      final s = service(client: apiClient(releaseJson(), onCall: () => calls++), clock: () => now);
      expect(await s.checkOnStartup(), isNotNull);
      now = now.add(const Duration(hours: 3));
      expect(await s.checkOnStartup(), isNull);
      expect(calls, 1);
      now = now.add(const Duration(hours: 10));
      expect(await s.checkOnStartup(), isNotNull);
      expect(calls, 2);
    });

    test('"Omitir esta versión" calla esa versión al abrir la app, no la siguiente', () async {
      var now = DateTime(2026, 11, 22);
      var json = releaseJson();
      final s = service(client: MockClient((_) async => http.Response(jsonEncode(json), 200)), clock: () => now);
      await s.skip(const AppVersion(1, 4, 0));
      expect(await s.checkOnStartup(), isNull);
      // Configuración la sigue ofreciendo.
      expect(await s.check(), isNotNull);

      json = releaseJson(tag: 'v1.4.1');
      now = now.add(const Duration(days: 1));
      expect((await s.checkOnStartup())!.version.toString(), '1.4.1');
    });
  });

  group('descarga', () {
    http.Client fileClient({List<int>? body, void Function()? onCall}) => MockClient.streaming((req, _) async {
          onCall?.call();
          final bytes = body ?? payload;
          // En trozos, como llega de verdad.
          final chunks = [for (var i = 0; i < bytes.length; i += 65536) bytes.sublist(i, (i + 65536).clamp(0, bytes.length))];
          return http.StreamedResponse(Stream.fromIterable(chunks), 200, contentLength: bytes.length);
        });

    AvailableUpdate update({String? digest}) => parseLatestRelease(
          releaseJson(digest: digest),
          platform: UpdatePlatform.android,
          current: const AppVersion(1, 3, 0),
        )!;

    test('baja el archivo, comprueba el hash y avisa el progreso', () async {
      final progress = <int>[];
      final file = await service(client: fileClient()).download(update(), onProgress: (r, _) => progress.add(r));
      expect(file.path, endsWith('Syncora-1.4.0.apk'));
      expect(await file.readAsBytes(), payload);
      expect(progress.last, payload.length);
      // No quedan temporales.
      expect(Directory('${tmp.path}/updates').listSync().map((e) => e.path.split(Platform.pathSeparator).last),
          ['Syncora-1.4.0.apk']);
    });

    test('un archivo alterado se rechaza y se borra', () async {
      final tampered = [...payload]..[1000] ^= 0xFF;
      await expectLater(
        service(client: fileClient(body: tampered)).download(update()),
        throwsA(isA<UpdateCorrupted>()),
      );
      expect(Directory('${tmp.path}/updates').listSync(), isEmpty);
    });

    test('una descarga cortada (menos bytes) se rechaza', () async {
      await expectLater(
        service(client: fileClient(body: payload.sublist(0, 1000))).download(update(digest: 'a' * 64)),
        throwsA(isA<UpdateCorrupted>()),
      );
    });

    test('si ya estaba bajado y verificado no se vuelve a bajar', () async {
      var calls = 0;
      final s = service(client: fileClient(onCall: () => calls++));
      await s.download(update());
      await s.download(update());
      expect(calls, 1);
    });

    test('cancelar detiene la descarga y no deja nada', () async {
      final token = UpdateCancelToken();
      await expectLater(
        service(client: fileClient()).download(update(), cancel: token, onProgress: (_, _) => token.cancel()),
        throwsA(isA<UpdateCancelled>()),
      );
      expect(Directory('${tmp.path}/updates').listSync(), isEmpty);
    });

    test('borra lo de versiones anteriores', () async {
      final dir = Directory('${tmp.path}/updates')..createSync(recursive: true);
      File('${dir.path}/Syncora-1.3.0.apk').writeAsBytesSync([1, 2, 3]);
      await service(client: fileClient()).download(update());
      expect(File('${dir.path}/Syncora-1.3.0.apk').existsSync(), isFalse);
    });
  });
}
