import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'desktop_auth_pages.dart';

/// Servicio de autenticación OAuth para Windows Desktop.
///
/// Usa un servidor HTTP loopback local en un PUERTO FIJO
/// (http://localhost:7734/auth/callback) como redirect URI.
///
/// Puerto fijo necesario para que Supabase pueda hacer match exacto en su
/// allowlist de Redirect URLs. Un puerto aleatorio no funciona porque
/// Supabase compara la URL completa incluyendo puerto.
///
/// URL que debe estar en Supabase Dashboard → Authentication → Redirect URLs:
///   http://localhost:7734/auth/callback
class DesktopAuthService {
  static const Duration _timeout = Duration(minutes: 5);

  /// Puerto fijo para el servidor de callback OAuth.
  /// Debe coincidir EXACTAMENTE con la URL registrada en Supabase Dashboard.
  static const int _callbackPort = 7734;
  static const String _callbackPath = '/auth/callback';
  static const String _redirectUri =
      'http://localhost:$_callbackPort$_callbackPath';

  /// Inicia el flujo de Google OAuth para Windows Desktop.
  ///
  /// 1. Inicia un HttpServer en el puerto fijo 7734.
  /// 2. Construye la URL de OAuth con redirectTo='http://localhost:7734/auth/callback'.
  /// 3. Abre el navegador con esa URL.
  /// 4. Espera el request de callback del browser (con el ?code= de PKCE).
  /// 5. Extrae el código de autorización del query string.
  /// 6. Responde al browser con una página HTML de éxito.
  /// 7. Intercambia el código por una sesión Supabase (PKCE).
  Future<void> signInWithGoogle() async {
    HttpServer? server;
    try {
      // 1. Iniciar servidor en el puerto FIJO 7734
      try {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, _callbackPort);
      } on SocketException catch (e) {
        throw AuthException(
          'El puerto $_callbackPort está en uso. Cierra otras instancias de la app e intenta de nuevo. ($e)',
        );
      }
      debugPrint('🌐 Servidor loopback iniciado en $_redirectUri');

      // 2. Generar URL de OAuth de Supabase con el redirect loopback.
      // signInWithOAuth abre el browser automáticamente en desktop.
      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: _redirectUri,
        authScreenLaunchMode: LaunchMode.externalApplication,
      );

      debugPrint('🔗 Browser abierto, esperando callback...');

      // 3. Esperar el callback del browser con timeout
      final request = await server.first.timeout(
        _timeout,
        onTimeout: () {
          throw const DesktopAuthTimeoutException();
        },
      );

      // 4. Extraer el código de autorización del query string
      final uri = request.uri;
      final code = uri.queryParameters['code'];
      final error = uri.queryParameters['error'];
      final errorDescription = uri.queryParameters['error_description'];

      debugPrint('📥 Callback recibido: ${uri.toString()}');

      if (error != null) {
        await _respondWithHtml(request, desktopAuthErrorPage(error, errorDescription));
        throw AuthException(
          'El proveedor OAuth devolvió un error: $errorDescription',
        );
      }

      if (code == null || code.isEmpty) {
        await _respondWithHtml(
          request,
          desktopAuthErrorPage(
            'no_code',
            'No se recibió un código de autorización en el callback.',
          ),
        );
        throw AuthException(
          'No se recibió un código de autorización en el callback OAuth.',
        );
      }

      // 5. Responder al browser con página de éxito
      await _respondWithHtml(request, desktopAuthSuccessPage());
      debugPrint('✅ Respuesta HTML enviada al browser');

      // 6. Cerrar el servidor (ya no necesitamos más requests)
      await server.close(force: false);
      server = null;

      // 7. Intercambiar el código por una sesión PKCE
      debugPrint('🔄 Intercambiando código por sesión...');
      await Supabase.instance.client.auth.exchangeCodeForSession(code);
      debugPrint('✅ Sesión establecida exitosamente');
    } finally {
      await server?.close(force: true);
    }
  }

  /// Envía una respuesta HTML al request del browser.
  Future<void> _respondWithHtml(HttpRequest request, String html) async {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.set(
      HttpHeaders.contentTypeHeader,
      'text/html; charset=utf-8',
    );
    request.response.write(html);
    await request.response.close();
  }
}

/// Excepción lanzada cuando el timeout de autenticación expira.
class DesktopAuthTimeoutException implements Exception {
  const DesktopAuthTimeoutException();

  @override
  String toString() =>
      'DesktopAuthTimeoutException: El tiempo de espera para la autenticación expiró (5 minutos).';
}
