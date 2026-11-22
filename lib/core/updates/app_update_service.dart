import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncora_android/syncora_android.dart';
import 'package:window_manager/window_manager.dart';

import '../settings/app_settings_store.dart';
import 'app_update.dart';

/// La descarga se canceló a pedido del usuario.
class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

/// El archivo bajado no es el que publicó GitHub (hash o tamaño distintos).
class UpdateCorrupted implements Exception {
  const UpdateCorrupted();
}

/// Para cancelar una descarga en curso.
class UpdateCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// Busca versiones nuevas en GitHub, las descarga verificadas y las instala.
///
/// La instalación es distinta en cada plataforma:
/// - **Android**: abre el instalador del sistema con el APK (el usuario
///   confirma; la primera vez Android le pide permitir instalar apps de
///   Syncora). Se instala encima solo si va firmado con la misma llave.
/// - **Windows**: corre el instalador en modo silencioso, cierra la app y el
///   instalador la vuelve a abrir al terminar (`/RELAUNCH=1`, ver
///   `installer/syncora.iss`).
class AppUpdateService {
  AppUpdateService({
    required this.platform,
    required this.settings,
    http.Client? client,
    Future<String> Function()? currentVersion,
    Future<Directory> Function()? downloadDir,
    DateTime Function()? clock,
  })  : _client = client ?? http.Client(),
        _currentVersion = currentVersion ?? _binaryVersion,
        _downloadDir = downloadDir ?? _defaultDownloadDir,
        _clock = clock ?? DateTime.now;

  /// `null` en plataformas que no se actualizan desde la app.
  final UpdatePlatform? platform;
  final AppSettingsStore settings;
  final http.Client _client;
  final Future<String> Function() _currentVersion;
  final Future<Directory> Function() _downloadDir;
  final DateTime Function() _clock;

  static const latestReleaseUrl = 'https://api.github.com/repos/NotJcao17/syncora-player/releases/latest';
  static const lastCheckKey = 'updates.last_check_ms';
  static const skippedVersionKey = 'updates.skipped_version';

  static Future<String> _binaryVersion() async => (await PackageInfo.fromPlatform()).version;

  /// Android: dentro de la caché (`cache/updates`), que es lo único que sirve
  /// el proveedor del plugin al instalador. Windows: `%TEMP%\SyncoraUpdate`.
  static Future<Directory> _defaultDownloadDir() async {
    final tmp = await getTemporaryDirectory();
    return Directory(p.join(tmp.path, Platform.isAndroid ? 'updates' : 'SyncoraUpdate'));
  }

  /// Consulta GitHub. Lanza si no hay red o GitHub responde con error; `null`
  /// si la instalada ya es la última.
  Future<AvailableUpdate?> check() async {
    final platform = this.platform;
    if (platform == null) return null;
    final current = AppVersion.tryParse(await _currentVersion());
    if (current == null) return null;
    final response = await _client.get(
      Uri.parse(latestReleaseUrl),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'SyncoraPlayer',
      },
    ).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw HttpException('GitHub respondió ${response.statusCode}');
    }
    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) throw const FormatException('Respuesta inesperada de GitHub');
    await settings.setInt(lastCheckKey, _clock().millisecondsSinceEpoch);
    return parseLatestRelease(json, platform: platform, current: current);
  }

  /// La consulta de al abrir la app: como mucho cada 12 h, nunca lanza y no
  /// devuelve la versión que el usuario pidió omitir.
  Future<AvailableUpdate?> checkOnStartup() async {
    if (platform == null) return null;
    final lastMs = settings.getInt(lastCheckKey);
    final last = lastMs == null ? null : DateTime.fromMillisecondsSinceEpoch(lastMs);
    if (!shouldCheckForUpdate(now: _clock(), lastCheck: last)) return null;
    try {
      final update = await check();
      if (update == null) return null;
      if (settings.getString(skippedVersionKey) == update.version.toString()) return null;
      return update;
    } catch (e) {
      debugPrint('[Updates] No se pudo buscar actualizaciones: $e');
      return null;
    }
  }

  /// "Omitir esta versión": no se vuelve a avisar de [version] al abrir la app
  /// (sí de la siguiente, y Configuración la sigue ofreciendo).
  Future<void> skip(AppVersion version) => settings.setString(skippedVersionKey, version.toString());

  /// Baja el archivo de [update] y comprueba tamaño y SHA-256. Si ya estaba
  /// bajado y verificado (p. ej. tras salir a dar el permiso de instalar), lo
  /// reutiliza.
  Future<File> download(
    AvailableUpdate update, {
    void Function(int received, int total)? onProgress,
    UpdateCancelToken? cancel,
  }) async {
    final dir = await _downloadDir();
    await dir.create(recursive: true);
    final target = File(p.join(dir.path, _localName(update)));
    if (await _isValid(target, update)) {
      onProgress?.call(update.size, update.size);
      return target;
    }
    // Restos de otras versiones o descargas a medias.
    await for (final entity in dir.list()) {
      if (entity is File) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }

    // Nombre propio por descarga: si el usuario cancela y vuelve a tocar
    // "Actualizar", la anterior todavía puede estar borrando su temporal.
    final part = File('${target.path}.${_clock().microsecondsSinceEpoch}.part');
    final request = http.Request('GET', Uri.parse(update.downloadUrl))
      ..headers['User-Agent'] = 'SyncoraPlayer';
    final response = await _client.send(request).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw HttpException('La descarga respondió ${response.statusCode}');
    }
    final sink = part.openWrite();
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    var received = 0;
    try {
      // Un corte de red a medias deja el stream colgado: 30 s sin datos es
      // un fallo.
      await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
        if (cancel?.isCancelled ?? false) throw const UpdateCancelled();
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        onProgress?.call(received, update.size);
      }
      await sink.flush();
    } catch (_) {
      await sink.close();
      await _deleteQuietly(part);
      rethrow;
    }
    await sink.close();
    hasher.close();
    final expected = update.sha256;
    if (received != update.size || (expected != null && digestSink.hex != expected)) {
      await _deleteQuietly(part);
      throw const UpdateCorrupted();
    }
    return part.rename(target.path);
  }

  /// Abre el instalador. En Windows la app se cierra y vuelve a abrirse sola
  /// ya actualizada; en Android el sistema toma el control. `false` si no se
  /// pudo lanzar.
  Future<bool> install(File file) async {
    switch (platform) {
      case UpdatePlatform.android:
        return SyncoraAndroid.installApk(file.path);
      case UpdatePlatform.windows:
        try {
          await Process.start(
            file.path,
            const ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/RELAUNCH=1'],
            mode: ProcessStartMode.detached,
          );
        } catch (e) {
          debugPrint('[Updates] No se pudo abrir el instalador: $e');
          return false;
        }
        // Mismo cierre que el botón X de la ventana.
        await windowManager.close();
        return true;
      case null:
        return false;
    }
  }

  static String _localName(AvailableUpdate u) {
    final ext = p.extension(u.fileName);
    return '${p.basenameWithoutExtension(u.fileName)}-${u.version}$ext';
  }

  Future<bool> _isValid(File file, AvailableUpdate update) async {
    try {
      if (!await file.exists() || await file.length() != update.size) return false;
      final expected = update.sha256;
      if (expected == null) return true;
      final path = file.path;
      // Leer 80 MB y calcular el hash bloquearía la interfaz un par de
      // segundos en el teléfono.
      final hex = await Isolate.run(() => sha256.convert(File(path).readAsBytesSync()).toString());
      return hex == expected;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;
  String get hex => _value.toString();

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}

final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  final UpdatePlatform? platform;
  if (kIsWeb) {
    platform = null;
  } else if (Platform.isAndroid) {
    platform = UpdatePlatform.android;
  } else if (Platform.isWindows) {
    platform = UpdatePlatform.windows;
  } else {
    platform = null;
  }
  return AppUpdateService(platform: platform, settings: ref.watch(appSettingsStoreProvider));
});
