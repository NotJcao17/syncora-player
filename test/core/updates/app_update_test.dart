import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/updates/app_update.dart';

Map<String, dynamic> release({
  String tag = 'v1.4.0',
  bool draft = false,
  bool prerelease = false,
  String body = '**Full Changelog**: https://github.com/NotJcao17/syncora-player/compare/v1.3.0...v1.4.0',
  List<Map<String, dynamic>>? assets,
}) =>
    {
      'tag_name': tag,
      'draft': draft,
      'prerelease': prerelease,
      'html_url': 'https://github.com/NotJcao17/syncora-player/releases/tag/$tag',
      'body': body,
      'assets': assets ??
          [
            {
              'name': 'Syncora.apk',
              'size': 87202009,
              'digest': 'sha256:31D389E7F35E438C206AD4C934BA9E61DF236FD449215AC8544C631DB960B3F0',
              'browser_download_url': 'https://github.com/NotJcao17/syncora-player/releases/download/$tag/Syncora.apk',
            },
            {
              'name': 'SyncoraSetup.exe',
              'size': 21835934,
              'browser_download_url': 'https://github.com/NotJcao17/syncora-player/releases/download/$tag/SyncoraSetup.exe',
            },
          ],
    };

void main() {
  const current = AppVersion(1, 3, 0);

  group('AppVersion', () {
    test('lee etiquetas y versiones del binario', () {
      expect(AppVersion.tryParse('v1.4.0'), const AppVersion(1, 4, 0));
      expect(AppVersion.tryParse('1.3.0+6'), const AppVersion(1, 3, 0));
      expect(AppVersion.tryParse('engine-channel'), isNull);
      expect(AppVersion.tryParse('v1.4'), isNull);
    });

    test('compara numéricamente, no como texto', () {
      expect(const AppVersion(1, 10, 0) > const AppVersion(1, 9, 9), isTrue);
      expect(const AppVersion(2, 0, 0) > const AppVersion(1, 99, 99), isTrue);
      expect(const AppVersion(1, 3, 0) > const AppVersion(1, 3, 0), isFalse);
    });
  });

  group('parseLatestRelease', () {
    test('versión nueva con el archivo de la plataforma', () {
      final u = parseLatestRelease(release(), platform: UpdatePlatform.android, current: current)!;
      expect(u.version, const AppVersion(1, 4, 0));
      expect(u.fileName, 'Syncora.apk');
      expect(u.size, 87202009);
      expect(u.sha256, '31d389e7f35e438c206ad4c934ba9e61df236fd449215ac8544c631db960b3f0');
      expect(u.downloadUrl, endsWith('/v1.4.0/Syncora.apk'));
    });

    test('Windows toma el instalador; sin digest no hay hash que comprobar', () {
      final u = parseLatestRelease(release(), platform: UpdatePlatform.windows, current: current)!;
      expect(u.fileName, 'SyncoraSetup.exe');
      expect(u.sha256, isNull);
    });

    test('misma versión o más vieja: nada que instalar', () {
      expect(parseLatestRelease(release(tag: 'v1.3.0'), platform: UpdatePlatform.android, current: current), isNull);
      expect(parseLatestRelease(release(tag: 'v1.2.9'), platform: UpdatePlatform.android, current: current), isNull);
    });

    test('borradores, pre-releases y etiquetas que no son versión se ignoran', () {
      expect(parseLatestRelease(release(draft: true), platform: UpdatePlatform.android, current: current), isNull);
      expect(parseLatestRelease(release(prerelease: true), platform: UpdatePlatform.android, current: current), isNull);
      expect(parseLatestRelease(release(tag: 'engine-channel'), platform: UpdatePlatform.android, current: current),
          isNull);
    });

    test('sin el archivo de la plataforma no se avisa', () {
      final r = release(assets: [
        {'name': 'SyncoraSetup.exe', 'size': 10, 'browser_download_url': 'https://x/SyncoraSetup.exe'},
      ]);
      expect(parseLatestRelease(r, platform: UpdatePlatform.android, current: current), isNull);
    });

    test('una URL que no es HTTPS se rechaza', () {
      final r = release(assets: [
        {'name': 'Syncora.apk', 'size': 10, 'browser_download_url': 'http://x/Syncora.apk'},
      ]);
      expect(parseLatestRelease(r, platform: UpdatePlatform.android, current: current), isNull);
    });
  });

  group('cleanReleaseNotes', () {
    test('lo de --generate-notes no cuenta como novedades', () {
      const body = "## What's Changed\n"
          '* Arreglo by @alguien in https://github.com/o/r/pull/3\n\n'
          '**Full Changelog**: https://github.com/o/r/compare/v1.3.0...v1.4.0';
      expect(cleanReleaseNotes(body), isEmpty);
    });

    test('se conserva lo escrito a mano', () {
      const body = '- Actualizar desde la app\r\n- Widgets nuevos\r\n\r\n**Full Changelog**: https://x';
      expect(cleanReleaseNotes(body), '- Actualizar desde la app\n- Widgets nuevos');
    });
  });

  group('shouldCheckForUpdate', () {
    final now = DateTime(2026, 11, 22, 12);

    test('primera vez y pasadas 12 h: sí; antes: no', () {
      expect(shouldCheckForUpdate(now: now, lastCheck: null), isTrue);
      expect(shouldCheckForUpdate(now: now, lastCheck: now.subtract(const Duration(hours: 13))), isTrue);
      expect(shouldCheckForUpdate(now: now, lastCheck: now.subtract(const Duration(hours: 2))), isFalse);
    });

    test('con el reloj movido hacia atrás se consulta', () {
      expect(shouldCheckForUpdate(now: now, lastCheck: now.add(const Duration(days: 3))), isTrue);
    });
  });

  test('formatUpdateSize', () {
    expect(formatUpdateSize(87202009), '83 MB');
    expect(formatUpdateSize(5 * 1024 * 1024 + 300000), '5.3 MB');
  });
}
