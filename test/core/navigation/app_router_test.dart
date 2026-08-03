import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/app.dart';
import 'package:syncora_player/core/navigation/app_router.dart';
import 'package:syncora_player/features/home/screens/home_screen.dart';
import 'package:syncora_player/features/library/screens/library_screen.dart';
import 'package:syncora_player/features/search/screens/search_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppRouter Widget Tests', () {
    testWidgets('navegar a / muestra HomeScreen', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: SyncoraApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('navegar a /search muestra SearchScreen', (tester) async {
      final container = ProviderContainer();
      final router = container.read(appRouterProvider);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();

      router.go('/search');
      await tester.pumpAndSettle();

      expect(find.byType(SearchScreen), findsOneWidget);
    });

    testWidgets('navegar a /library muestra LibraryScreen', (tester) async {
      final container = ProviderContainer();
      final router = container.read(appRouterProvider);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();

      router.go('/library');
      await tester.pumpAndSettle();

      expect(find.byType(LibraryScreen), findsOneWidget);
    });
  });
}
