import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/navigation/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../services/account_limit_error.dart';
import '../services/auth_deep_link_errors.dart';
import '../services/desktop_auth_service.dart';

/// Pantalla de Autenticación para Syncora Player.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  int _selectedTabIndex = 0; // 0: Login, 1: Registro
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;
  // Fase 7.H.4: cupo de 250 cuentas alcanzado (D-22), detectado con
  // `looksLikeAccountLimitError` (`account_limit_error.dart`). Se distingue
  // del resto de errores de auth para mostrar un mensaje propio en el
  // `build()` de abajo, no un error genérico ni un "inténtalo más tarde" --
  // el botón "usar sin cuenta" del plan (7.I) todavía no se agrega ahí a
  // propósito: 7.I (modo local) no está implementado en este punto de la
  // fase, se cablea cuando exista.
  bool _accountLimitReached = false;
  StreamSubscription<AuthState>? _authSubscription;
  StreamSubscription<String>? _deepLinkErrorSubscription;

  @override
  void initState() {
    super.initState();
    if (!_isTestEnvironment()) {
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ref.read(appRouterProvider).go('/');
          }
        });
      }

      _authSubscription =
          Supabase.instance.client.auth.onAuthStateChange.listen((data) {
        if (data.session != null && mounted) {
          ref.read(appRouterProvider).go('/');
        }
      });

      // Fase 7.H.5: en Android/iOS el resultado del login con Google llega
      // por un deep link procesado en `main.dart`, fuera de esta pantalla
      // -- si ese callback trae un error (ej. cupo de cuentas lleno, 7.H.2)
      // en vez de una sesión, `main.dart` lo publica acá en vez de dejarlo
      // desaparecer en silencio.
      _deepLinkErrorSubscription = authDeepLinkErrors.stream.listen((message) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          if (looksLikeAccountLimitError(message)) {
            _accountLimitReached = true;
          } else {
            _errorMessage = message;
          }
        });
      });
    }
  }

  static const String _googleSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
  <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.66 0 6.6 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/>
  <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/>
  <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.28-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24s.92 7.54 2.56 10.78l7.97-6.19z"/>
  <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.6 42.62 14.66 48 24 48z"/>
</svg>
''';

  @override
  void dispose() {
    _authSubscription?.cancel();
    _deepLinkErrorSubscription?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool _isTestEnvironment() {
    return Platform.environment.containsKey('FLUTTER_TEST');
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _accountLimitReached = false;
    });

    try {
      if (!_isTestEnvironment()) {
        if (!kIsWeb && Platform.isWindows) {
          // En Windows usamos un servidor HTTP loopback local para el callback.
          // Esto evita que el navegador se quede cargando al redirigir a un
          // esquema personalizado (syncoraplayer://) que no devuelve respuesta HTTP.
          await DesktopAuthService().signInWithGoogle();
        } else {
          // En Android/iOS/otras plataformas usamos deep links nativos.
          await Supabase.instance.client.auth.signInWithOAuth(
            OAuthProvider.google,
            redirectTo: 'syncoraplayer://login-callback',
          );
        }
      }
    } on DesktopAuthTimeoutException {
      if (mounted) {
        setState(() {
          _errorMessage = 'El tiempo de espera para la autenticación expiró. Inténtalo de nuevo.';
        });
      }
    } catch (e) {
      // El flujo de Windows (`DesktopAuthService`) envuelve el error que
      // Supabase devuelve en el redirect de OAuth (incluido el rechazo del
      // hook) en una `AuthException` propia -- ver `desktop_auth_service.dart`.
      final rawMessage = e is AuthException ? e.message : e.toString();
      if (mounted) {
        setState(() {
          if (looksLikeAccountLimitError(rawMessage)) {
            _accountLimitReached = true;
          } else {
            _errorMessage = 'Error al iniciar sesión con Google: $rawMessage';
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handleSubmitForm() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _accountLimitReached = false;
    });

    final email = _emailController.text.trim();
    final password = _passwordController.text;

    try {
      if (!_isTestEnvironment()) {
        if (_selectedTabIndex == 0) {
          // Login
          await Supabase.instance.client.auth.signInWithPassword(
            email: email,
            password: password,
          );
        } else {
          // Registro -> auto-login tras signUp
          await Supabase.instance.client.auth.signUp(
            email: email,
            password: password,
          );
        }
      }
    } on AuthException catch (e) {
      if (mounted) {
        setState(() {
          if (looksLikeAccountLimitError(e.message)) {
            _accountLimitReached = true;
          } else {
            _errorMessage = e.message;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Ocurrió un error inesperado: ${e.toString()}';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String? _validateEmail(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Ingresa un correo electrónico';
    }
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (!emailRegex.hasMatch(value.trim())) {
      return 'Ingresa un correo válido';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Ingresa una contraseña';
    }
    if (value.length < 8) {
      return 'La contraseña debe tener al menos 8 caracteres';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF181C27),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(20),
              boxShadow: AppTheme.surfaceShadow,
              border: Border.all(
                color: AppTheme.surfaceActive.withValues(alpha: 0.5),
                width: 1,
              ),
            ),
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Logo de Syncora Centrado
                Center(
                  child: Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.asset(
                          'assets/icon/icon.png',
                          width: 64,
                          height: 64,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: AppTheme.gradientLiked,
                              boxShadow: AppTheme.glowShadow,
                            ),
                            child: const Icon(
                              Icons.graphic_eq,
                              size: 36,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Syncora Player',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.primary,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Tu música, sincronizada en todo lugar',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.secondary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),

                // Fase 7.H.4: cupo de cuentas lleno -- mensaje propio, no un
                // error genérico ni un "inténtalo más tarde". El botón
                // "usar sin cuenta" del plan (7.I) todavía no se agrega acá
                // a propósito: 7.I (modo local) no está implementado en
                // este punto de la fase, y un botón que no lleva a ningún
                // lado sería peor que no mostrarlo -- se cablea en 7.I.3
                // cuando exista `localModeProvider`/la pantalla real.
                if (_accountLimitReached) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0x26F59E0B),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.5),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.people_outline,
                          color: Color(0xFFF59E0B),
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            accountLimitMessage,
                            style: const TextStyle(
                              color: Color(0xFFFBBF24),
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // Alerta de Error (si existe)
                if (_errorMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0x26EF4444),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFFEF4444).withValues(alpha: 0.5),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: Color(0xFFEF4444),
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(
                              color: Color(0xFFFCA5A5),
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // Botón Prominente "Continuar con Google"
                ElevatedButton(
                  onPressed: _isLoading ? null : _handleGoogleSignIn,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black87,
                    minimumSize: const Size.fromHeight(50),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SvgPicture.string(
                        _googleSvg,
                        width: 20,
                        height: 20,
                      ),
                      const SizedBox(width: 10),
                      const Flexible(
                        child: Text(
                          'Continuar con Google',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Divisor con texto "o"
                Row(
                  children: [
                    const Expanded(
                      child: Divider(color: AppTheme.surfaceActive, thickness: 1),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'o',
                        style: TextStyle(
                          color: AppTheme.muted,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Expanded(
                      child: Divider(color: AppTheme.surfaceActive, thickness: 1),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // Selector de Pestañas: Login / Registro
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: AppTheme.background,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedTabIndex = 0;
                              _errorMessage = null;
                              _accountLimitReached = false;
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: _selectedTabIndex == 0
                                  ? AppTheme.surfaceActive
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              'Iniciar Sesión',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: _selectedTabIndex == 0
                                    ? AppTheme.primary
                                    : AppTheme.muted,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedTabIndex = 1;
                              _errorMessage = null;
                              _accountLimitReached = false;
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: _selectedTabIndex == 1
                                  ? AppTheme.surfaceActive
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              'Registro',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: _selectedTabIndex == 1
                                    ? AppTheme.primary
                                    : AppTheme.muted,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Formulario Secundario (Email + Password)
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        validator: _validateEmail,
                        style: const TextStyle(
                          color: AppTheme.primary,
                          fontSize: 14,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Correo electrónico',
                          labelStyle: const TextStyle(
                            color: AppTheme.secondary,
                            fontSize: 13,
                          ),
                          filled: true,
                          fillColor: AppTheme.background,
                          prefixIcon: const Icon(
                            Icons.email_outlined,
                            color: AppTheme.secondary,
                            size: 20,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: AppTheme.accent,
                              width: 1.5,
                            ),
                          ),
                          errorBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFFEF4444),
                              width: 1,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),

                      TextFormField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        validator: _validatePassword,
                        style: const TextStyle(
                          color: AppTheme.primary,
                          fontSize: 14,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Contraseña',
                          labelStyle: const TextStyle(
                            color: AppTheme.secondary,
                            fontSize: 13,
                          ),
                          filled: true,
                          fillColor: AppTheme.background,
                          prefixIcon: const Icon(
                            Icons.lock_outline,
                            color: AppTheme.secondary,
                            size: 20,
                          ),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              color: AppTheme.secondary,
                              size: 20,
                            ),
                            onPressed: () {
                              setState(() {
                                _obscurePassword = !_obscurePassword;
                              });
                            },
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: AppTheme.accent,
                              width: 1.5,
                            ),
                          ),
                          errorBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                              color: Color(0xFFEF4444),
                              width: 1,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),

                      // Tarjeta de Advertencia Ámbar/Naranja en la pestaña Registro
                      if (_selectedTabIndex == 1) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0x26F59E0B),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: const Color(0xFFF59E0B).withValues(alpha: 0.5),
                            ),
                          ),
                          child: const Text(
                            '⚠️ No hay recuperación de contraseña disponible. Si olvidas tu contraseña perderás el acceso. Recomendamos usar Google.',
                            style: TextStyle(
                              color: Color(0xFFFBBF24),
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              height: 1.35,
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                      ],

                      // Botón de Submit
                      ElevatedButton(
                        onPressed: _isLoading ? null : _handleSubmitForm,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.surfaceActive,
                          foregroundColor: AppTheme.primary,
                          minimumSize: const Size.fromHeight(46),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          elevation: 0,
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppTheme.primary,
                                ),
                              )
                            : Text(
                                _selectedTabIndex == 0
                                    ? 'Iniciar Sesión'
                                    : 'Crear Cuenta',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
