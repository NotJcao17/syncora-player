import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
        await _respondWithHtml(request, _buildErrorHtml(error, errorDescription));
        throw AuthException(
          'El proveedor OAuth devolvió un error: $errorDescription',
        );
      }

      if (code == null || code.isEmpty) {
        await _respondWithHtml(
          request,
          _buildErrorHtml(
            'no_code',
            'No se recibió un código de autorización en el callback.',
          ),
        );
        throw AuthException(
          'No se recibió un código de autorización en el callback OAuth.',
        );
      }

      // 5. Responder al browser con página de éxito
      await _respondWithHtml(request, _buildSuccessHtml());
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

  /// Construye la página HTML de éxito que se muestra en el browser.
  String _buildSuccessHtml() {
    return '''<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Syncora Player &mdash; Autenticación Exitosa</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #0f1117;
      color: #e2e8f0;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      padding: 24px;
    }
    .card {
      background: #1a1d2e;
      border: 1px solid rgba(123, 92, 250, 0.3);
      border-radius: 20px;
      padding: 48px 40px;
      max-width: 420px;
      width: 100%;
      text-align: center;
      box-shadow: 0 25px 50px rgba(0, 0, 0, 0.5), 0 0 60px rgba(123, 92, 250, 0.1);
    }
    .icon {
      width: 72px;
      height: 72px;
      background: linear-gradient(135deg, #7b5cfa, #a78bfa);
      border-radius: 20px;
      display: flex;
      align-items: center;
      justify-content: center;
      margin: 0 auto 24px;
      font-size: 36px;
      box-shadow: 0 8px 32px rgba(123, 92, 250, 0.4);
    }
    h1 {
      font-size: 22px;
      font-weight: 700;
      color: #f1f5f9;
      margin-bottom: 12px;
      letter-spacing: -0.3px;
    }
    p { font-size: 15px; color: #94a3b8; line-height: 1.6; margin-bottom: 8px; }
    .hint { font-size: 13px; color: #64748b; margin-top: 20px; }
    .pulse {
      display: inline-block;
      width: 8px;
      height: 8px;
      background: #22c55e;
      border-radius: 50%;
      margin-right: 6px;
      animation: pulse 2s infinite;
    }
    @keyframes pulse {
      0%, 100% { opacity: 1; transform: scale(1); }
      50% { opacity: 0.5; transform: scale(0.8); }
    }
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">&#10003;</div>
    <h1>&#161;Autenticaci&#243;n Exitosa!</h1>
    <p><span class="pulse"></span>Has iniciado sesi&#243;n en <strong>Syncora Player</strong>.</p>
    <p>Regresa a la aplicaci&#243;n para continuar.</p>
    <p class="hint">Puedes cerrar esta pesta&#241;a.</p>
  </div>
  <script>
    try { window.close(); } catch(e) {}
    setTimeout(function() { try { window.close(); } catch(e) {} }, 500);
  </script>
</body>
</html>''';
  }

  /// Construye la página HTML de error.
  String _buildErrorHtml(String error, String? description) {
    final safeDesc = description ?? 'Error desconocido en la autenticación.';
    return '''<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Syncora Player &mdash; Error de Autenticaci&#243;n</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #0f1117;
      color: #e2e8f0;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      padding: 24px;
    }
    .card {
      background: #1a1d2e;
      border: 1px solid rgba(239, 68, 68, 0.3);
      border-radius: 20px;
      padding: 48px 40px;
      max-width: 420px;
      width: 100%;
      text-align: center;
      box-shadow: 0 25px 50px rgba(0, 0, 0, 0.5);
    }
    .icon {
      width: 72px;
      height: 72px;
      background: linear-gradient(135deg, #ef4444, #f87171);
      border-radius: 20px;
      display: flex;
      align-items: center;
      justify-content: center;
      margin: 0 auto 24px;
      font-size: 36px;
      box-shadow: 0 8px 32px rgba(239, 68, 68, 0.3);
    }
    h1 { font-size: 22px; font-weight: 700; color: #f1f5f9; margin-bottom: 12px; }
    p { font-size: 15px; color: #94a3b8; line-height: 1.6; margin-bottom: 8px; }
    .code { font-size: 12px; color: #ef4444; font-family: monospace; margin-top: 16px; }
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">&#10007;</div>
    <h1>Error de Autenticaci&#243;n</h1>
    <p>$safeDesc</p>
    <p class="code">$error</p>
  </div>
</body>
</html>''';
  }
}

/// Excepción lanzada cuando el timeout de autenticación expira.
class DesktopAuthTimeoutException implements Exception {
  const DesktopAuthTimeoutException();

  @override
  String toString() =>
      'DesktopAuthTimeoutException: El tiempo de espera para la autenticación expiró (5 minutos).';
}
