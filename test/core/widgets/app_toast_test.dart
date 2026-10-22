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

  // Ronda 10: al guardar una playlist el teclado se cierra justo después de
  // mostrar el aviso, y el aviso se quedaba a media pantalla (a la altura del
  // teclado que ya no estaba).
  testWidgets('el aviso baja a su sitio cuando se cierra el teclado', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    BuildContext? ctx;
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.expand();
        })),
      ),
    ));

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    AppToast.show(ctx!, message: 'Playlist actualizada');
    await tester.pump();
    final withKeyboard = tester.getBottomLeft(find.text('Playlist actualizada')).dy;
    expect(withKeyboard, lessThan(800 - 300));

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    final withoutKeyboard = tester.getBottomLeft(find.text('Playlist actualizada')).dy;
    expect(withoutKeyboard, greaterThan(800 - 150));

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('sin teclado el aviso queda donde siempre', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    BuildContext? ctx;
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.expand();
        })),
      ),
    ));
    AppToast.show(ctx!, message: 'Agregada a la cola');
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    // Con chrome (por defecto) y sin mini reproductor medido: alto 0 + 12.
    final positioned = tester.widget<AnimatedPositioned>(find.byType(AnimatedPositioned));
    expect(positioned.bottom, 12.0);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
