import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/navigation/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/apis/deezer_provider.dart';
import '../../../data/local_db/database_provider.dart';
import '../../../data/supabase/supabase_providers.dart';
import '../../library/import_export/playlist_import_export_service.dart';
import '../local_mode_provider.dart';
import '../services/account_limit_error.dart';
import '../services/auth_deep_link_errors.dart';
import '../services/desktop_auth_service.dart';
import '../services/new_account_heuristic.dart';

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
  // `build()` de abajo, no un error genérico ni un "inténtalo más tarde".
  // El botón "usar sin cuenta" vive en `_buildLocalModeButton` (7.I.3).
  bool _accountLimitReached = false;
  bool _isMigrating = false;
  // El overlay de `_isMigrating` se usa para dos operaciones opuestas
  // (subir la biblioteca local vs. descartarla): sin esto le decía
  // "Subiendo tu biblioteca local a la nube..." a alguien que en realidad
  // está viendo cómo se borra.
  bool _isDiscarding = false;
  // Guarda de reentrancia para todo el bloque de resolución de datos
  // locales: dos eventos de sesión casi seguidos podían apilar dos
  // diálogos de confirmación / dos pasadas de borrado.
  bool _isResolvingLocalData = false;
  StreamSubscription<AuthState>? _authSubscription;
  StreamSubscription<String>? _deepLinkErrorSubscription;
  // Distingue "me estoy registrando" (subir mi biblioteca local a la cuenta
  // nueva) de "estoy iniciando sesión en una cuenta que ya existe" (avisar y
  // descartar lo local, la nube manda). `null` = no se sabe de antemano
  // (Google: Supabase no le dice al cliente si fue alta o login: se resuelve
  // con [_looksLikeNewAccount] cuando llega la sesión). Se resetea al
  // arrancar cada intento nuevo para no arrastrar el de un intento previo.
  bool? _isSignUpAttempt;

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
          Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
        final session = data.session;
        if (session != null && mounted) {
          // Fase 7.I.10 (D-25) + corrección post-Fase-7 (pruebas manuales):
          // si el usuario estaba en modo local y recién se creó una sesión
          // real, hay que resolver los datos locales ANTES de navegar --
          // después de esto ya no hay forma fácil de distinguir "acabo de
          // iniciar sesión" de "siempre tuve cuenta". Dos caminos, según si
          // la cuenta es nueva o ya existía (nunca se había definido esto
          // antes -- ver docstring de [_handleLocalDataOnLogin]).
          //
          // `shouldNavigate` en `false` significa que el usuario canceló el
          // descarte de datos locales -- ya se cerró la sesión de vuelta
          // adentro de `_handleLocalDataOnLogin`, así que NO hay que navegar
          // a `/` (nos quedamos en `/auth`, todavía en modo local).
          var shouldNavigate = true;
          if (ref.read(localModeProvider)) {
            // El notifier es global y sobrevive a esta pantalla; se captura
            // ANTES de cualquier `await` porque `ref` no se puede tocar una
            // vez que el `State` se destruyó. `appRouterProvider` ya no se
            // reconstruye al llegar la sesión (era la causa del bug real,
            // ver su docstring), así que hoy la pantalla debería seguir
            // viva -- pero de esto depende que el usuario no quede sin
            // salida, así que no se apoya en eso.
            final localMode = ref.read(localModeProvider.notifier);
            // `_isSignUpAttempt == true` (pestaña Registro) no se toma como
            // palabra: un `signUp` sobre un correo que ya existe puede
            // devolver sesión de la cuenta vieja, y ahí migrar a ciegas es
            // exactamente lo que este bloque intenta evitar. Solo el login
            // explícito ("no es alta") se acepta sin verificar.
            final isNewAccount = _isSignUpAttempt == false
                ? false
                : looksLikeNewAccount(
                    createdAt: session.user.createdAt,
                    lastSignInAt: session.user.lastSignInAt,
                  );
            try {
              shouldNavigate = await _handleLocalDataOnLogin(isNewAccount: isNewAccount);
            } catch (_) {
              shouldNavigate = true;
            }
            // Red de seguridad del bug real: quedar con sesión creada y el
            // flag de modo local todavía en `true` no tiene salida desde la
            // UI. Cualquier camino que no sea "el usuario canceló" tiene que
            // terminar sí o sí fuera de modo local, aunque el paso previo
            // haya fallado o esta pantalla ya no exista. `disable()` es
            // idempotente, así que repetirlo tras un camino que ya lo hizo
            // no tiene costo.
            if (shouldNavigate) {
              try {
                await localMode.disable();
              } catch (_) {}
            }
          }
          if (mounted && shouldNavigate) ref.read(appRouterProvider).go('/');
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

  /// Fase 7.I.3 (D-23): "Usar sin cuenta". No requiere red ni Supabase --
  /// solo marca el modo local y navega. `localModeProvider` está `watch`eado
  /// por `appRouterProvider`, así que el redirect se reevalúa apenas cambia
  /// el estado; el `go('/')` explícito es solo para no depender del timing
  /// exacto de esa reconstrucción.
  Future<void> _useWithoutAccount() async {
    await ref.read(localModeProvider.notifier).enable();
    if (mounted) ref.read(appRouterProvider).go('/');
  }

  /// Fase 7.I.10 (D-25): sube la biblioteca local (playlists + álbumes
  /// guardados) a la cuenta recién creada. Migración one-way, best-effort --
  /// si falla a mitad de camino, el usuario sigue teniendo su biblioteca
  /// intacta en Drift local. La recuperación real ante un fallo/crash a
  /// mitad de la migración es un reintento automático al próximo arranque
  /// de la app (`main.dart`, ver comentario ahí) -- no un botón manual en
  /// Configuración, que dejaría de tener a dónde apuntar apenas hay sesión
  /// (`computeAuthRedirect` ya no deja volver a `/auth` con `hasUser`).
  ///
  /// Guardado con [_isMigrating] contra reentrancia (hallazgo de la
  /// revisión independiente): dos eventos de sesión nueva casi seguidos
  /// (ej. el listener de `onAuthStateChange` disparando más de una vez)
  /// podían lanzar dos migraciones concurrentes y subir todo duplicado.
  Future<void> _migrateLocalLibrary() async {
    if (!mounted || _isMigrating) return;
    setState(() => _isMigrating = true);
    try {
      final service = PlaylistImportExportService(ref.read(deezerApiProvider));
      await service.migrateLocalPlaylistsToAccount(
        dao: ref.read(playlistDaoProvider),
        supabaseRepo: ref.read(supabasePlaylistRepositoryProvider),
      );
      await service.migrateLocalSavedAlbumsToAccount(
        savedAlbumDao: ref.read(savedAlbumDaoProvider),
        supabaseAlbumRepo: ref.read(supabaseAlbumRepositoryProvider),
      );
    } catch (_) {
      // Best-effort -- lo que no se subió queda local, sin `remoteId`, y
      // se retoma solo en el próximo arranque (ver `main.dart`).
    } finally {
      await ref.read(localModeProvider.notifier).disable();
      if (mounted) setState(() => _isMigrating = false);
    }
  }

  /// Nunca se había definido qué hacer con los datos del modo local al
  /// iniciar sesión en una cuenta que YA existe (a diferencia de registrarse,
  /// donde [_migrateLocalLibrary] los sube) -- decisión tomada tras pruebas
  /// manuales reales: una cuenta nueva absorbe lo local (nada que perder,
  /// la cuenta nace vacía); una cuenta existente, en cambio, ya tiene su
  /// propia biblioteca en la nube -- mezclarla a ciegas con lo local
  /// (coincidencia de títulos, ver `migrateLocalPlaylistsToAccount`) puede
  /// crear playlists duplicadas por coincidencia de nombre. Se le avisa al
  /// usuario y se descarta lo local a favor de lo que ya hay en la nube.
  ///
  /// Devuelve `false` si el usuario canceló (ya se cerró la sesión de vuelta
  /// acá adentro) -- el llamador no debe navegar a `/` en ese caso.
  Future<bool> _handleLocalDataOnLogin({required bool isNewAccount}) async {
    // Reentrante: la pasada que ya está en curso es la que decide y navega.
    if (_isResolvingLocalData) return false;
    _isResolvingLocalData = true;
    try {
      if (isNewAccount) {
        await _migrateLocalLibrary();
        return true;
      }

      bool hasLocalData;
      try {
        hasLocalData = await _hasAnyLocalLibraryData();
      } catch (_) {
        // No se pudo determinar si hay algo que perder -> no se borra nada.
        // Las playlists local-only sobreviven al sync (solo se podan las que
        // ya tienen `remoteId`), así que el usuario las sigue viendo y puede
        // decidir él; lo que no puede pasar es quedarse en modo local.
        hasLocalData = false;
      }
      if (!hasLocalData) return true;

      // Sin pantalla viva no hay dónde mostrar el diálogo. Salir de modo
      // local sin borrar nada es el resultado seguro: el usuario conserva
      // sus datos y queda con su cuenta usable, en vez de trabado.
      if (!mounted) return true;

      final shouldDiscard = await _confirmDiscardLocalData();
      if (shouldDiscard != true) {
        try {
          await Supabase.instance.client.auth.signOut();
        } catch (_) {
          if (mounted) {
            setState(() {
              _errorMessage = 'No se pudo revertir el inicio de sesión. '
                  'Cierra sesión desde Configuración si quieres seguir sin cuenta.';
            });
          }
          // Con la sesión todavía viva, quedarse en modo local es
          // justamente el estado sin salida del bug -- se continúa.
          return true;
        }
        return false;
      }

      await _discardLocalLibraryAndDisableLocalMode();
      return true;
    } finally {
      _isResolvingLocalData = false;
    }
  }

  /// Playlists no-"Tus me gusta" (cualquiera cuenta), o "Tus me gusta" con
  /// al menos una canción, o algún álbum guardado -- lo mínimo para
  /// considerar que hay algo real que el usuario perdería si se descarta en
  /// silencio. Evita mostrar el diálogo de advertencia a alguien que apenas
  /// probó el modo local sin guardar nada todavía.
  Future<bool> _hasAnyLocalLibraryData() async {
    final dao = ref.read(playlistDaoProvider);
    final savedAlbumDao = ref.read(savedAlbumDaoProvider);
    final playlists = await dao.getAllPlaylists();
    if (playlists.any((p) => !p.isLiked)) return true;

    final liked = await dao.getLikedPlaylist();
    final likedTracks = await dao.getTracksOrdered(liked.id);
    if (likedTracks.isNotEmpty) return true;

    final albums = await savedAlbumDao.getAllSavedAlbums();
    return albums.isNotEmpty;
  }

  Future<bool?> _confirmDiscardLocalData() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Esta cuenta ya tiene datos en la nube',
          style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Estabas usando el modo local con tus propias playlists y álbumes guardados. '
          'Si continúas, esos datos locales se van a borrar de este dispositivo y se '
          'reemplazan por los de la cuenta con la que acabas de iniciar sesión. '
          'Esta acción no se puede deshacer.',
          style: TextStyle(color: AppTheme.secondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar, seguir en modo local'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar datos locales y continuar', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  /// Borra la biblioteca local (pistas de todas las playlists; las playlists
  /// no-"Tus me gusta" enteras -- la de "Tus me gusta" es una fila reservada
  /// que se vacía pero no se borra; álbumes guardados; historial de escucha
  /// local completo) antes de salir de modo local -- a partir de ahí, los
  /// puntos de sincronización normales de la app (ya gateados por
  /// `isLocalMode`, 7.I.5) traen la biblioteca real de la cuenta al aterrizar
  /// en `/`.
  ///
  /// El historial de escucha se borra también (decisión del usuario, no solo
  /// las playlists/álbumes): sin esto, `syncListeningHistory()` sube igual
  /// las escuchas acumuladas en modo local en el próximo sync, contaminando
  /// las estadísticas y el Wrapped de una cuenta que no es de donde salieron.
  ///
  /// Las descargas locales (`DownloadedTracks`) NO se tocan a propósito: son
  /// específicas del dispositivo por diseño (Fase 6), nunca se sincronizan
  /// con ninguna cuenta, y borrarlas destruiría archivos de audio reales ya
  /// descargados sin que el usuario lo haya pedido explícitamente -- a
  /// diferencia de playlists/álbumes/historial, conservarlas no contamina ni
  /// mezcla nada de la cuenta con la que se acaba de iniciar sesión.
  ///
  /// Las pistas de playlist se borran a mano incluso en las playlists que se
  /// eliminan enteras: el `ON DELETE CASCADE` declarado en `PlaylistTracks`
  /// NO se aplica en runtime, porque la base nunca ejecuta `PRAGMA
  /// foreign_keys = ON` (sqlite3 la trae apagada por defecto). Sin esto, cada
  /// `deletePlaylist` dejaba las filas de `playlist_tracks` huérfanas en
  /// disco -- invisibles en la UI, pero contradiciendo lo que el diálogo le
  /// promete al usuario ("tus datos locales se van a borrar").
  Future<void> _discardLocalLibraryAndDisableLocalMode() async {
    // Los DAOs se resuelven antes de cualquier `await`: `ref` no se puede
    // usar si esta pantalla se destruye a mitad del borrado, y el borrado
    // ya confirmado por el usuario no debería quedar a medias por eso.
    final dao = ref.read(playlistDaoProvider);
    final savedAlbumDao = ref.read(savedAlbumDaoProvider);
    final historyDao = ref.read(listeningHistoryDaoProvider);
    if (mounted) {
      setState(() {
        _isMigrating = true;
        _isDiscarding = true;
      });
    }
    try {
      final playlists = await dao.getAllPlaylists();
      for (final playlist in playlists) {
        final tracks = await dao.getTracksOrdered(playlist.id);
        for (final track in tracks) {
          await dao.removeTrackEntry(track.id);
        }
        if (!playlist.isLiked) {
          await dao.deletePlaylist(playlist.id);
        }
      }

      final albums = await savedAlbumDao.getAllSavedAlbums();
      for (final album in albums) {
        await savedAlbumDao.removeSavedAlbum(album.albumId);
      }

      await historyDao.deleteAll();
    } catch (_) {
      // Best-effort -- el usuario ya confirmó que quiere descartar; lo que
      // no se pudo borrar queda local-only, un estado ya soportado (H-5).
    } finally {
      if (mounted) {
        setState(() {
          _isMigrating = false;
          _isDiscarding = false;
        });
      }
    }
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _accountLimitReached = false;
    });
    // Google no distingue alta de login del lado del cliente -- se resuelve
    // con la heurística de `_looksLikeNewAccount` cuando llegue la sesión.
    _isSignUpAttempt = null;

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
          _isSignUpAttempt = false;
          await Supabase.instance.client.auth.signInWithPassword(
            email: email,
            password: password,
          );
        } else {
          // Registro -> auto-login tras signUp
          _isSignUpAttempt = true;
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
      // Fase 7.I.10: overlay simple durante la migración local -> cuenta --
      // dura lo que tarde subir la biblioteca (potencialmente varias
      // playlists), el usuario necesita saber que algo está pasando en vez
      // de ver la pantalla de login congelada tras crear la cuenta.
      body: _isMigrating
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: AppTheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    _isDiscarding
                        ? 'Borrando tu biblioteca local...'
                        : 'Subiendo tu biblioteca local a la nube...',
                    style: const TextStyle(color: AppTheme.secondary, fontSize: 13),
                  ),
                ],
              ),
            )
          : Center(
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

                // Fase 7.I.3 (D-23): "Usar sin cuenta" -- opción de primera
                // clase, no letra chica escondida: mismo tamaño de texto y
                // ubicación visible que el resto del flujo, con una
                // explicación honesta de la contrapartida (sin sync, sin
                // respaldo, sin IA) en vez de solo el botón pelado.
                const SizedBox(height: 20),
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
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: _isLoading ? null : _useWithoutAccount,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.secondary,
                    side: const BorderSide(color: AppTheme.surfaceActive),
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Usar sin cuenta', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Tu biblioteca se guarda solo en este dispositivo. Sin sincronización, sin respaldo '
                  'y sin funciones de IA.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.muted, fontSize: 11, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
