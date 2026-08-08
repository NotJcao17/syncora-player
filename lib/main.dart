import 'dart:io';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';

void _registerWindowsProtocolHandler() {
  if (!kIsWeb && Platform.isWindows) {
    try {
      final exePath = Platform.resolvedExecutable;
      final regCmd =
          'reg add "HKCU\\Software\\Classes\\syncoraplayer" /ve /t REG_SZ /d "URL:Syncora Player Protocol" /f && '
          'reg add "HKCU\\Software\\Classes\\syncoraplayer" /v "URL Protocol" /t REG_SZ /d "" /f && '
          'reg add "HKCU\\Software\\Classes\\syncoraplayer\\shell\\open\\command" /ve /t REG_SZ /d "\\"$exePath\\" \\"%1\\"" /f';
      Process.run('cmd.exe', ['/c', regCmd]);
    } catch (_) {}
  }
}

Future<void> _handleAuthDeepLink(Uri uri) async {
  debugPrint('🔗 Deep Link recibido: $uri');
  try {
    await Supabase.instance.client.auth.getSessionFromUrl(uri);
    debugPrint('✅ getSessionFromUrl completado');
  } catch (e) {
    debugPrint('⚠️ Error en getSessionFromUrl: $e');
  }

  // Fallback: extraer tokens o código si getSessionFromUrl no actualizó la sesión activa
  final currentSession = Supabase.instance.client.auth.currentSession;
  if (currentSession == null) {
    final fragment = uri.fragment;
    final query = uri.queryParameters;

    String? accessToken = query['access_token'];
    String? refreshToken = query['refresh_token'];
    String? code = query['code'];

    if ((accessToken == null || accessToken.isEmpty) && fragment.isNotEmpty) {
      final params = Uri.splitQueryString(fragment);
      accessToken = params['access_token'];
      refreshToken = params['refresh_token'];
      code ??= params['code'];
    }

    if (code != null && code.isNotEmpty) {
      try {
        await Supabase.instance.client.auth.exchangeCodeForSession(code);
        debugPrint('✅ exchangeCodeForSession manual exitoso');
      } catch (ex) {
        debugPrint('⚠️ exchangeCodeForSession manual falló: $ex');
      }
    } else if (refreshToken != null && refreshToken.isNotEmpty) {
      try {
        await Supabase.instance.client.auth.setSession(refreshToken);
        debugPrint('✅ setSession manual exitoso');
      } catch (ex) {
        debugPrint('⚠️ setSession manual falló: $ex');
      }
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Cargar variables de entorno
  try {
    await dotenv.load(fileName: ".env");
  } catch (_) {}

  // Init sqflite_common_ffi en Windows
  if (!kIsWeb && Platform.isWindows) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _registerWindowsProtocolHandler();
  }

  // Init Supabase
  final rawUrl = dotenv.env['SUPABASE_URL'] ?? '';
  final rawKey = dotenv.env['SUPABASE_ANON_KEY'] ?? '';

  final validUrl = (rawUrl.isNotEmpty &&
          rawUrl != 'tu_url_aqui' &&
          (rawUrl.startsWith('http://') || rawUrl.startsWith('https://')))
      ? rawUrl
      : 'https://placeholder.supabase.co';

  final validKey = (rawKey.isNotEmpty && rawKey != 'tu_anon_key_aqui')
      ? rawKey
      : 'placeholder-anon-key';

  await Supabase.initialize(
    url: validUrl,
    publishableKey: validKey,
  );

  // AppLinks listener para Deep Links / OAuth redirect callbacks
  final appLinks = AppLinks();
  try {
    final initialUri = await appLinks.getInitialLink();
    if (initialUri != null) {
      await _handleAuthDeepLink(initialUri);
    }
  } catch (_) {}

  appLinks.uriLinkStream.listen((uri) async {
    await _handleAuthDeepLink(uri);
  });

  // MediaKit, SMTCWindows y WindowManager solo se inicializan en Windows
  if (!kIsWeb && Platform.isWindows) {
    MediaKit.ensureInitialized();
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      size: Size(1280, 720),
      minimumSize: Size(900, 600),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
      await SMTCWindows.initialize();
    });
  }

  runApp(
    const ProviderScope(
      child: SyncoraApp(),
    ),
  );
}
