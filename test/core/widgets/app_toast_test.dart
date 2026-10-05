import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:syncora_player/core/widgets/app_toast.dart';

void main() {
  // Ronda 6 (H-R6-10): un aviso desde una hoja abierta en el navegador de un
  // `ShellRoute` (la de "Elige tu avatar", desde Configuración) congelaba la
  // app: `GoRouterState.of` entraba en un bucle infinito.
  testWidgets('un aviso desde una hoja del shell no congela la app', (tester) async {
    final shellKey = GlobalKey<NavigatorState>();
    BuildContext? sheetContext;
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        ShellRoute(
          navigatorKey: shellKey,
          builder: (context, state, child) => Scaffold(body: child),
          routes: [
            GoRoute(
              path: '/settings',
              builder: (context, state) => Builder(
                builder: (context) => TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (ctx) {
                      sheetContext = ctx;
                      return const SizedBox(height: 200);
                    },
                  ),
                  child: const Text('abrir'),
                ),
              ),
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(ProviderScope(child: MaterialApp.router(routerConfig: router)));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(sheetContext, isNotNull);

    AppToast.show(sheetContext!, message: 'Foto de perfil actualizada');
    await tester.pump();
    expect(find.text('Foto de perfil actualizada'), findsOneWidget);

    // Deja que el aviso se cierre solo para no dejar timers pendientes.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
