import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/auth/services/account_limit_error.dart';

void main() {
  group('looksLikeAccountLimitError (Fase 7.H.4)', () {
    test('detecta el mensaje personalizado del hook (7.H.2)', () {
      expect(
        looksLikeAccountLimitError(
          'Las cuentas con nube de Syncora Player están llenas por ahora. Puedes seguir usando la '
          'app sin cuenta mientras se libera cupo.',
        ),
        isTrue,
      );
    });

    test('detecta el bug conocido de la plataforma (mensaje genérico del hook)', () {
      expect(looksLikeAccountLimitError('Invalid payload sent to hook'), isTrue);
    });

    test('es insensible a mayúsculas/minúsculas en ambas formas', () {
      expect(looksLikeAccountLimitError('INVALID PAYLOAD SENT TO HOOK'), isTrue);
      expect(looksLikeAccountLimitError('LAS CUENTAS CON NUBE están llenas'), isTrue);
    });

    test('NO confunde errores de auth normales con el cupo lleno', () {
      expect(looksLikeAccountLimitError('Invalid login credentials'), isFalse);
      expect(looksLikeAccountLimitError('User already registered'), isFalse);
      expect(looksLikeAccountLimitError('Password should be at least 6 characters'), isFalse);
    });
  });
}
