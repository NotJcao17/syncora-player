import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/auth/local_mode_provider.dart';
import '../../features/auth/screens/auth_screen.dart';
import '../../features/download/screens/downloads_screen.dart';
import '../../features/home/screens/home_screen.dart';

import '../../features/library/screens/album_detail_screen.dart';
import '../../features/library/screens/library_screen.dart';
import '../../features/library/screens/playlist_detail_screen.dart';
import '../../features/player/screens/player_fullscreen_screen.dart';
import '../../features/search/screens/artist_detail_screen.dart';
import '../../features/search/screens/search_screen.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../features/stats/screens/stats_screen.dart';
import '../layout/app_shell.dart';

final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<NavigatorState> _shellNavigatorKey = GlobalKey<NavigatorState>();

class GoRouterRefreshStream extends ChangeNotifier {
  late final StreamSubscription<dynamic> _subscription;

  GoRouterRefreshStream(Stream<dynamic> stream) {
    notifyListeners();
    _subscription = stream.asBroadcastStream().listen(
          (dynamic _) => notifyListeners(),
        );
  }

  /// Permite re-evaluar el `redirect` ante cambios que no vienen del stream
  /// de auth (hoy: `localModeProvider`), sin tener que reconstruir el
  /// `GoRouter` entero -- ver el comentario de [appRouterProvider].
  void refresh() => notifyListeners();

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

/// Fase 7.I.2/7.I.12 -- decisión de redirect de auth, extraída como función
/// pura para poder testearla sin GoRouter/Supabase: el `redirect` real de
/// abajo se salta por completo en entorno de test (`isTestEnv`), así que
/// sin esta extracción la lógica de gate nunca se ejercita en ningún test
/// (los tests de router existentes navegan libremente porque el bypass ya
/// las deja pasar, no porque el gate las deje pasar).
///
/// D-24: `hasUser == false && isLocalMode == false` es la única condición
/// que fuerza `/auth` -- el modo local es un gate adicional al de sesión,
/// no un reemplazo.
///
/// Bug real (pruebas manuales): `hasUser && isAuthRoute -> '/'` sin más
/// condición sacaba al usuario de `/auth` apenas llegaba la sesión, mientras
/// `auth_screen.dart` todavía estaba resolviendo qué hacer con los datos del
/// modo local (su listener de `onAuthStateChange` migra/descarta y recién
/// DESPUÉS llama `localModeProvider.notifier.disable()`) -- el `State` se
/// destruía a mitad y el flag quedaba pegado en `true` con sesión real. Se
/// agrega `&& !isLocalMode`: el router no mueve a nadie mientras el modo
/// local siga activo; navega `auth_screen.dart` cuando terminó, y el
/// `disable()` reevalúa este redirect vía `refreshListenable`.
///
/// Esta condición es necesaria pero NO era suficiente por sí sola: la otra
/// mitad del bug estaba en que `appRouterProvider` se reconstruía con cada
/// cambio de sesión, y eso reseteaba la ubicación sin pasar por acá -- ver
/// el docstring de [appRouterProvider].
String? computeAuthRedirect({
  required bool hasUser,
  required bool isLocalMode,
  required String location,
}) {
  final isAuthRoute = location == '/auth';

  if (!hasUser && !isLocalMode && !isAuthRoute) {
    return '/auth';
  }
  if (hasUser && isAuthRoute && !isLocalMode) {
    return '/';
  }
  return null;
}

/// Provider de Riverpod para GoRouter.
///
/// Este provider NO puede hacer `ref.watch` de nada que cambie durante la
/// vida de la app. `SyncoraApp` hace `ref.watch(appRouterProvider)`, así que
/// cualquier reconstrucción entrega una instancia NUEVA de `GoRouter` a
/// `MaterialApp.router` -- y un `GoRouter` nuevo arranca en su
/// `initialLocation` ('/'), sin pasar por `computeAuthRedirect`. Verificado
/// con un test de widget: tras cambiar la instancia, la ubicación vuelve a
/// '/' aunque el redirect diga que no hay que moverse.
///
/// Eso era el bug real reportado en pruebas manuales: al llegar la sesión,
/// `currentUserProvider` cambiaba, este provider se reconstruía y la
/// `AuthScreen` se destruía en pleno flujo de resolución de datos locales
/// (su diálogo de confirmación sobrevivía porque se apoya en el
/// `NavigatorState` del `_rootNavigatorKey` compartido, pero el `State` de
/// la pantalla detrás ya no existía). Al confirmar, todo el trabajo
/// pendiente se saltaba por los chequeos de `mounted` y el flag de modo
/// local nunca se limpiaba: sesión creada, modo local pegado en `true` y
/// sin salida desde la UI.
///
/// Por eso el estado se lee DENTRO del `redirect` (que se re-ejecuta cada
/// vez que `refreshListenable` avisa) en lugar de capturarse al construir.
final appRouterProvider = Provider<GoRouter>((ref) {
  final isTestEnv = Platform.environment.containsKey('FLUTTER_TEST');

  final refreshListenable =
      isTestEnv ? null : GoRouterRefreshStream(Supabase.instance.client.auth.onAuthStateChange);
  // `listen`, nunca `watch`: el modo local tiene que reevaluar el redirect
  // (el stream de auth no cubre "Usar sin cuenta" ni el `disable()` del
  // final de la migración) sin reconstruir este provider.
  ref.listen(localModeProvider, (_, _) => refreshListenable?.refresh());
  if (refreshListenable != null) {
    ref.onDispose(refreshListenable.dispose);
  }

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/',
    refreshListenable: refreshListenable,
    redirect: (context, state) {
      if (isTestEnv) {
        return null;
      }

      return computeAuthRedirect(
        hasUser: Supabase.instance.client.auth.currentUser != null,
        isLocalMode: ref.read(localModeProvider),
        location: state.uri.path,
      );
    },
    routes: [
      // Auth Screen fuera del Shell (pantalla completa sin bottom nav / sidebar)
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/auth',
        pageBuilder: (context, state) => const NoTransitionPage(
          child: AuthScreen(),
        ),
      ),

      // Shell Route que persiste el layout adaptativo (AppShell con MiniPlayer)
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) {
          return AppShell(
            location: state.uri.toString(),
            child: child,
          );
        },
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: HomeScreen(),
            ),
          ),
          GoRoute(
            path: '/search',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: SearchScreen(),
            ),
          ),
          GoRoute(
            path: '/library',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: LibraryScreen(),
            ),
          ),
          GoRoute(
            path: '/playlist/:id',
            pageBuilder: (context, state) {
              final id = state.pathParameters['id'] ?? '';
              return NoTransitionPage(
                child: PlaylistDetailScreen(playlistId: id),
              );
            },
          ),
          GoRoute(
            path: '/album/:id',
            pageBuilder: (context, state) {
              final id = state.pathParameters['id'] ?? '';
              return NoTransitionPage(
                child: AlbumDetailScreen(albumId: id),
              );
            },
          ),
          GoRoute(
            path: '/artist/:id',
            pageBuilder: (context, state) {
              final id = state.pathParameters['id'] ?? '';
              return NoTransitionPage(
                child: ArtistDetailScreen(artistId: id),
              );
            },
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: SettingsScreen(),
            ),
          ),
          GoRoute(
            path: '/downloads',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: DownloadsScreen(),
            ),
          ),
          GoRoute(
            path: '/stats',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: StatsScreen(),
            ),
          ),

        ],
      ),

      // Reproductor Fullscreen fuera del Shell (modal deslizable limpio)
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/player',
        pageBuilder: (context, state) => CustomTransitionPage(
          child: const PlayerFullscreenScreen(),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return SlideTransition(
              position: animation.drive(
                Tween<Offset>(
                  begin: const Offset(0, 1),
                  end: Offset.zero,
                ).chain(CurveTween(curve: Curves.easeOutCubic)),
              ),
              child: child,
            );
          },
        ),
      ),
    ],
  );
});
