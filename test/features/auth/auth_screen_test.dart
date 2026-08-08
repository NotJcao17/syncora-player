import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/auth/screens/auth_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AuthScreen Widget Tests', () {
    testWidgets('Renders AuthScreen with logo, Google button, and form', (tester) async {
      tester.view.physicalSize = const Size(1280, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: AuthScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Syncora Player'), findsOneWidget);
      expect(find.text('Continuar con Google'), findsOneWidget);
      expect(find.text('Iniciar Sesión'), findsWidgets);
      expect(find.text('Registro'), findsOneWidget);
    });

    testWidgets('Switching to Registro tab displays warning card', (tester) async {
      tester.view.physicalSize = const Size(1280, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: AuthScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final registroTab = find.text('Registro');
      await tester.tap(registroTab);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('⚠️ No hay recuperación de contraseña disponible'),
        findsOneWidget,
      );
      expect(find.text('Crear Cuenta'), findsOneWidget);
    });
  });
}
