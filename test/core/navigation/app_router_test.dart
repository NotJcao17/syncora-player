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
      tester.view.physicalSize = const Size(1280, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const ProviderScope(
          child: SyncoraApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1000));

      expect(find.byType(HomeScreen), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1000));
    });

    testWidgets('navegar a /search muestra SearchScreen', (tester) async {
      tester.view.physicalSize = const Size(1280, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

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

      router.go('/search');
      await tester.pump(const Duration(milliseconds: 1000));

      expect(find.byType(SearchScreen), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1000));
      container.dispose();
    });

    testWidgets('navegar a /library muestra LibraryScreen', (tester) async {
      tester.view.physicalSize = const Size(1280, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

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

      router.go('/library');
      await tester.pump(const Duration(milliseconds: 1000));

      expect(find.byType(LibraryScreen), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1000));
      container.dispose();
    });
  });
}
