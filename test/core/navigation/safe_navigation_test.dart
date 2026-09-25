import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:syncora_player/core/navigation/safe_navigation.dart';

final _root = GlobalKey<NavigatorState>();
final _shell = GlobalKey<NavigatorState>();

GoRouter _router() => GoRouter(
      navigatorKey: _root,
      initialLocation: '/',
      routes: [
        ShellRoute(
          navigatorKey: _shell,
          builder: (context, state, child) => Scaffold(body: child),
          routes: [
            GoRoute(
              path: '/',
              pageBuilder: (c, s) => NoTransitionPage(
                key: s.pageKey,
                child: Builder(
                  builder: (ctx) => TextButton(onPressed: () => ctx.push('/player'), child: const Text('abrir player')),
                ),
              ),
            ),
            GoRoute(
              path: '/artist/:id',
              pageBuilder: (c, s) => NoTransitionPage(key: s.pageKey, child: Text('artista ${s.pathParameters['id']}')),
            ),
          ],
        ),
        GoRoute(
          parentNavigatorKey: _root,
          path: '/player',
          pageBuilder: (c, s) => CustomTransitionPage(
            key: s.pageKey,
            transitionsBuilder: (ctx, a, sa, child) => child,
            child: Scaffold(
              body: Builder(
                builder: (playerCtx) => Column(
                  children: [
                    TextButton(
                      onPressed: () => navigateSafely(playerCtx, '/artist/1'),
                      child: const Text('ir directo'),
                    ),
                    TextButton(
                      onPressed: () => showModalBottomSheet<void>(
                        context: playerCtx,
                        builder: (sheetCtx) => TextButton(
                          onPressed: () {
                            Navigator.pop(sheetCtx);
                            navigateSafely(playerCtx, '/artist/2');
                          },
                          child: const Text('desde hoja'),
                        ),
                      ),
                      child: const Text('abrir hoja'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );

void main() {
  testWidgets('desde el reproductor a pantalla completa', (tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: _router()));
    await tester.tap(find.text('abrir player'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'al abrir el player');
    await tester.tap(find.text('ir directo'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('artista 1'), findsOneWidget);
  });

  testWidgets('desde una hoja encima del reproductor', (tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: _router()));
    await tester.tap(find.text('abrir player'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('abrir hoja'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('desde hoja'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('artista 2'), findsOneWidget);
  });
}
