import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/navigation/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/services/remote_account_check.dart';
class SyncoraApp extends ConsumerWidget {
  const SyncoraApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    // Ronda 7: cierres de sesión que hace Supabase solo (cuenta eliminada o
    // sesión cerrada en otro dispositivo). Vive lo que vive la app.
    ref.watch(serverSignOutWatcherProvider);

    return MaterialApp.router(
      title: 'Syncora Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      routerConfig: router,
    );
  }
}
