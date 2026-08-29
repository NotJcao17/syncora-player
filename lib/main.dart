import 'dart:io';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'package:window_manager/window_manager.dart';
import 'package:background_downloader/background_downloader.dart';
import 'app.dart';
import 'features/auth/local_mode_provider.dart';
import 'features/auth/services/auth_deep_link_errors.dart';
import 'features/auth/services/local_mode_storage.dart';

Future<void> _handleAuthDeepLink(Uri rawUri) async {
  final rawString = rawUri.toString().trim();
  debugPrint('🔗 Deep Link recibido: $rawString');

  Uri targetUri = rawUri;
  if (rawString.contains('syncoraplayer://')) {
    final idx = rawString.indexOf('syncoraplayer://');
    final cleanUrl = rawString.substring(idx);
    final parsed = Uri.tryParse(cleanUrl);
    if (parsed != null) {
      targetUri = parsed;
    }
  }

  // Fase 7.H.5 (hallazgo de la revisión independiente): si el callback de
  // OAuth trae un error (`error`/`error_description`, en query o fragment
  // según el flujo), no hay sesión que extraer -- avisar por
  // `authDeepLinkErrors` en vez de caer en el camino de abajo, que solo
  // sabe buscar tokens/código y se queda en silencio si no encuentra
  // ninguno. Cubre, entre otros, el rechazo del hook "Before User Created"
  // por cupo de cuentas lleno (7.H.2) en Android/iOS.
  final fragmentParams =
      targetUri.fragment.isNotEmpty ? Uri.splitQueryString(targetUri.fragment) : const <String, String>{};
  final errorCode = targetUri.queryParameters['error'] ?? fragmentParams['error'];
  final errorDescription = targetUri.queryParameters['error_description'] ?? fragmentParams['error_description'];
  if (errorCode != null && errorCode.isNotEmpty) {
    debugPrint('⚠️ Deep link de OAuth con error: $errorCode ($errorDescription)');
    authDeepLinkErrors.add(errorDescription ?? errorCode);
    return;
  }

  try {
    await Supabase.instance.client.auth.getSessionFromUrl(targetUri);
    debugPrint('✅ getSessionFromUrl completado');
  } catch (e) {
    debugPrint('⚠️ getSessionFromUrl error: $e');
  }

  // Fallback: si el cliente aún no inició sesión, intentar extraer tokens o código
  final currentSession = Supabase.instance.client.auth.currentSession;
  if (currentSession == null) {
    final fragment = targetUri.fragment;
    final query = targetUri.queryParameters;

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

  // Edge-to-edge transparent status bar y navigation bar en Android y tema oscuro
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Configurar background_downloader (Doze Mode / WorkManager en Android)
  if (!kIsWeb) {
    try {
      await FileDownloader().configure(
        globalConfig: [(Config.requestTimeout, const Duration(seconds: 60))],
        androidConfig: [(Config.holdingQueue, null)],
      );
    } catch (_) {}
  }

  // Cargar variables de entorno
  try {
    await dotenv.load(fileName: ".env");
  } catch (_) {}

  // Init sqflite_common_ffi en Windows
  if (!kIsWeb && Platform.isWindows) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
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
    authOptions: const FlutterAuthClientOptions(
      authFlowType: AuthFlowType.pkce,
    ),
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

    // SMTC debe quedar inicializado (y esperado) ANTES de `runApp()`: los
    // controles de hover de la barra de tareas nunca aparecían porque esta
    // llamada vivía sin `await` dentro del callback de
    // `waitUntilReadyToShow` -- una carrera con `runApp()` de más abajo, que
    // sigue de largo sin esperar a que ese callback termine. El primer
    // provider que lee `syncoraPlayerControllerProvider` (ya durante el
    // primer build) construye `WindowsMediaControls`, que a su vez crea el
    // `SMTCWindows` real -- si `RustLib.init()` (dentro de
    // `SMTCWindows.initialize()`) todavía no había corrido en ese momento,
    // esa construcción lanzaba una excepción atrapada en silencio por su
    // propio try/catch, y SMTC quedaba sin registrar para toda la sesión.
    await SMTCWindows.initialize();

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
    });
  }

  // Fase 7.I.1: precargar el modo local ANTES de `runApp` -- `localModeProvider`
  // se lee de forma síncrona en el `redirect` de `app_router.dart` (GoRouter
  // no permite un redirect asíncrono ahí), así que el valor persistido tiene
  // que estar listo desde el primer frame, no cargarse después vía
  // `FutureProvider`.
  final localModeStorage = SecureLocalModeStorage();
  bool initialLocalMode = false;
  try {
    initialLocalMode = await localModeStorage.getIsLocalMode();
  } catch (_) {}

  // Hallazgo de la revisión independiente de 7.I: si la app se cerró (o
  // crasheó) a mitad de `_migrateLocalLibrary` (`auth_screen.dart`), el
  // `finally` que limpia el flag de modo local nunca llegó a correr -- el
  // flag persistido queda en `true` con una sesión real ya establecida
  // (Supabase también persiste su sesión en disco, independiente de esto).
  // Sin este chequeo, `computeAuthRedirect` no rebota a nadie (`hasUser`
  // manda), pero el resto de la UI (Configuración, `library_screen.dart`,
  // `app_shell.dart`) queda mostrando el estado "modo local" para un
  // usuario que en realidad ya tiene cuenta -- sin "Cerrar sesión" visible
  // y sin forma de llegar a `/auth` (`computeAuthRedirect` rebota `/auth`
  // a `/` porque `hasUser == true`). Se autocorrige acá: si ya hay sesión
  // real, el flag persistido es obsoleto, se descarta antes de inyectarlo.
  // (Las playlists locales que hubieran quedado a mitad de subir no se
  // pierden -- quedan como playlists local-only normales, ya un estado
  // soportado, ver H-5 -- pero no se reintenta su migración automáticamente
  // tras este punto.)
  if (initialLocalMode) {
    try {
      if (Supabase.instance.client.auth.currentUser != null) {
        initialLocalMode = false;
        await localModeStorage.setLocalMode(false);
      }
    } catch (_) {}
  }

  runApp(
    ProviderScope(
      overrides: [
        localModeStorageProvider.overrideWithValue(localModeStorage),
        localModeProvider.overrideWith(() => LocalModeNotifier(initialLocalMode)),
      ],
      child: const SyncoraApp(),
    ),
  );
}
