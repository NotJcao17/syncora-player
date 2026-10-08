import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncora_player/features/auth/services/remote_account_check.dart';

void main() {
  group('classifyAccountCheckError: solo una respuesta explícita del servidor cuenta', () {
    test('403 user_not_found = cuenta eliminada', () {
      expect(
        classifyAccountCheckError(const AuthApiException('User from sub claim in JWT does not exist',
            statusCode: '403', code: 'user_not_found')),
        RemoteAccountStatus.deleted,
      );
    });

    test('403 session_not_found = sesión cerrada en el servidor', () {
      expect(
        classifyAccountCheckError(const AuthApiException('Session from session_id claim in JWT does not exist',
            statusCode: '403', code: 'session_not_found')),
        RemoteAccountStatus.sessionRevoked,
      );
    });

    test('cualquier otra cosa es "no se sabe" y nunca borra', () {
      for (final e in <Object>[
        const AuthApiException('x', statusCode: '401', code: 'user_not_found'),
        const AuthApiException('x', statusCode: '403', code: 'bad_jwt'),
        const AuthApiException('User from sub claim in JWT does not exist', statusCode: '403'),
        const AuthApiException('x', statusCode: '500'),
        AuthRetryableFetchException(message: 'sin red'),
        Exception('timeout'),
      ]) {
        expect(classifyAccountCheckError(e), RemoteAccountStatus.unknown, reason: '$e');
      }
    });
  });

  test('el aviso pendiente se entrega una vez y no pisa uno más específico', () {
    setPendingAuthNotice(accountDeletedElsewhereNotice);
    setPendingAuthNotice(sessionClosedNotice, keepExisting: true);
    expect(takePendingAuthNotice(), accountDeletedElsewhereNotice);
    expect(takePendingAuthNotice(), isNull);
  });

  group('RemoteAccountChecker', () {
    late String? userId;
    late int fetchCalls;
    late Object? fetchError;
    late bool expired;
    late int refreshCalls;
    late Object? refreshError;
    late DateTime now;
    late RemoteAccountChecker checker;

    setUp(() {
      userId = 'u1';
      fetchCalls = 0;
      fetchError = null;
      expired = false;
      refreshCalls = 0;
      refreshError = null;
      now = DateTime(2026, 10, 8, 12);
      checker = RemoteAccountChecker(
        currentUserId: () => userId,
        fetchUser: () async {
          fetchCalls++;
          if (fetchError != null) throw fetchError!;
        },
        sessionExpired: () => expired,
        refreshSession: () async {
          refreshCalls++;
          if (refreshError != null) throw refreshError!;
        },
        now: () => now,
      );
    });

    test('sin sesión no pregunta nada', () async {
      userId = null;
      expect((await checker.check()).status, RemoteAccountStatus.unknown);
      expect(fetchCalls, 0);
    });

    test('la cuenta existe: se recuerda 5 minutos por usuario', () async {
      expect((await checker.check()).status, RemoteAccountStatus.exists);
      now = now.add(const Duration(minutes: 4));
      expect((await checker.check()).status, RemoteAccountStatus.exists);
      expect(fetchCalls, 1);
      now = now.add(const Duration(minutes: 2));
      await checker.check();
      expect(fetchCalls, 2);
      userId = 'u2';
      await checker.check();
      expect(fetchCalls, 3, reason: 'otra cuenta no usa lo recordado de la anterior');
    });

    test('dos comprobaciones a la vez hacen una sola petición', () async {
      final results = await Future.wait([checker.check(), checker.check()]);
      expect(results.map((r) => r.status), everyElement(RemoteAccountStatus.exists));
      expect(fetchCalls, 1);
    });

    test('una comprobación en curso de otra cuenta no se reutiliza', () async {
      final first = checker.check();
      userId = 'u2';
      final second = checker.check();
      expect((await first).userId, 'u1');
      expect((await second).userId, 'u2');
      expect(fetchCalls, 2);
    });

    test('cuenta eliminada: devuelve el usuario que el servidor rechazó', () async {
      fetchError = const AuthApiException('gone', statusCode: '403', code: 'user_not_found');
      final r = await checker.check();
      expect(r.status, RemoteAccountStatus.deleted);
      expect(r.userId, 'u1');
    });

    test('token vencido: renueva antes de preguntar; si la renovación falla, no se sabe', () async {
      expired = true;
      await checker.check();
      expect(refreshCalls, 1);
      expect(fetchCalls, 1);

      refreshError = const AuthApiException('Invalid Refresh Token', statusCode: '400', code: 'refresh_token_not_found');
      final r = await checker.check(force: true);
      expect(r.status, RemoteAccountStatus.unknown);
      expect(fetchCalls, 1, reason: 'sin token válido /user no diría nada útil');
    });
  });
}
