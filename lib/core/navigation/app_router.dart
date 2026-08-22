import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/auth/auth_provider.dart';
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
String? computeAuthRedirect({
  required bool hasUser,
  required bool isLocalMode,
  required String location,
}) {
  final isAuthRoute = location == '/auth';

  if (!hasUser && !isLocalMode && !isAuthRoute) {
    return '/auth';
  }
  if (hasUser && isAuthRoute) {
    return '/';
  }
  return null;
}

/// Provider de Riverpod para GoRouter.
final appRouterProvider = Provider<GoRouter>((ref) {
  final currentUser = ref.watch(currentUserProvider);
  // Fase 7.I.2: `ref.watch` (no `read`) para que tocar "Usar sin cuenta" en
  // `auth_screen.dart` reconstruya este provider y el redirect se
  // reevalúe de inmediato, mismo mecanismo que ya usa `currentUser`.
  final isLocalMode = ref.watch(localModeProvider);
  final isTestEnv = Platform.environment.containsKey('FLUTTER_TEST');

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/',
    refreshListenable: isTestEnv ? null : GoRouterRefreshStream(Supabase.instance.client.auth.onAuthStateChange),
    redirect: (context, state) {
      if (isTestEnv) {
        return null;
      }

      return computeAuthRedirect(
        hasUser: currentUser != null,
        isLocalMode: isLocalMode,
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
