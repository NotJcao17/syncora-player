import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/navigation/app_router.dart';

/// Fase 7.I.2/7.I.12 -- `computeAuthRedirect` es la lógica de gate extraída
/// de `appRouterProvider.redirect` para poder testearla: el `redirect` real
/// se salta por completo en entorno de test (`isTestEnv`), así que sin esta
/// extracción el gate nunca se ejercitaba en ningún test -- los tests de
/// router existentes navegan libremente porque el bypass los deja pasar,
/// no porque el gate los deje pasar.
void main() {
  group('computeAuthRedirect (Fase 7.I.2/7.I.12)', () {
    test('sin usuario y sin modo local -> redirige a /auth (comportamiento pre-7.I)', () {
      expect(
        computeAuthRedirect(hasUser: false, isLocalMode: false, location: '/'),
        '/auth',
      );
    });

    test('sin usuario pero en modo local -> NO redirige (D-23/D-24, el punto central de 7.I)', () {
      expect(
        computeAuthRedirect(hasUser: false, isLocalMode: true, location: '/'),
        isNull,
      );
      expect(
        computeAuthRedirect(hasUser: false, isLocalMode: true, location: '/library'),
        isNull,
      );
      expect(
        computeAuthRedirect(hasUser: false, isLocalMode: true, location: '/settings'),
        isNull,
      );
    });

    test('sin usuario, sin modo local, ya en /auth -> no redirige en bucle', () {
      expect(
        computeAuthRedirect(hasUser: false, isLocalMode: false, location: '/auth'),
        isNull,
      );
    });

    test('con usuario, en /auth, sin modo local -> redirige a / (login/registro exitoso)', () {
      expect(
        computeAuthRedirect(hasUser: true, isLocalMode: false, location: '/auth'),
        '/',
      );
    });

    // Bug real corregido en pruebas manuales: con usuario Y modo local
    // todavía activo (justo tras iniciar sesión, antes de que
    // `auth_screen.dart` termine de migrar/descartar los datos locales y
    // llame `disable()`), el router NO debe sacar al usuario de `/auth` --
    // antes lo hacía (`hasUser` mandaba sin más condición), lo que ganaba la
    // carrera contra el listener de `auth_screen.dart` y dejaba el flag de
    // modo local pegado en `true` para siempre con una sesión real ya
    // creada. Es `auth_screen.dart` quien navega una vez que resolvió los
    // datos locales.
    test('con usuario Y modo local todavía activo, en /auth -> NO redirige (evita la carrera con auth_screen.dart)', () {
      expect(
        computeAuthRedirect(hasUser: true, isLocalMode: true, location: '/auth'),
        isNull,
      );
    });

    test('con usuario, fuera de /auth -> no redirige', () {
      expect(
        computeAuthRedirect(hasUser: true, isLocalMode: false, location: '/library'),
        isNull,
      );
    });
  });
}
