import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/navigation/app_router.dart';
import 'core/theme/app_theme.dart';
import 'data/sync/realtime_providers.dart';

class SyncoraApp extends ConsumerWidget {
  const SyncoraApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Eagerly initialize WebSockets realtime synchronization for logged-in user
    ref.watch(realtimeSyncServiceProvider);

    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Syncora Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      routerConfig: router,
    );
  }
}
