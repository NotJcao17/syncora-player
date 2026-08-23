import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/auth/services/new_account_heuristic.dart';

void main() {
  group('looksLikeNewAccount', () {
    const created = '2026-08-22T10:00:00.000Z';

    test('sin lastSignInAt -> cuenta nueva (lado seguro)', () {
      expect(looksLikeNewAccount(createdAt: created, lastSignInAt: null), isTrue);
    });

    test('lastSignInAt idéntico a createdAt -> cuenta nueva', () {
      expect(looksLikeNewAccount(createdAt: created, lastSignInAt: created), isTrue);
    });

    test('lastSignInAt pocos segundos después -> cuenta nueva', () {
      expect(
        looksLikeNewAccount(createdAt: created, lastSignInAt: '2026-08-22T10:00:09.000Z'),
        isTrue,
      );
    });

    test('lastSignInAt justo fuera de la ventana -> cuenta existente', () {
      expect(
        looksLikeNewAccount(createdAt: created, lastSignInAt: '2026-08-22T10:00:11.000Z'),
        isFalse,
      );
    });

    test('lastSignInAt meses después -> cuenta existente', () {
      expect(
        looksLikeNewAccount(createdAt: created, lastSignInAt: '2026-11-02T18:30:00.000Z'),
        isFalse,
      );
    });

    // Zonas horarias distintas en cada timestamp: la comparación tiene que
    // ser sobre el instante absoluto, no sobre el texto.
    test('mismo instante expresado con offsets distintos -> cuenta nueva', () {
      expect(
        looksLikeNewAccount(
          createdAt: '2026-08-22T10:00:00.000Z',
          lastSignInAt: '2026-08-22T07:00:02.000-03:00',
        ),
        isTrue,
      );
    });

    // Reloj del servidor corregido hacia atrás entre las dos escrituras: la
    // diferencia se toma en valor absoluto, no queda negativa.
    test('lastSignInAt levemente ANTERIOR a createdAt -> cuenta nueva', () {
      expect(
        looksLikeNewAccount(createdAt: created, lastSignInAt: '2026-08-22T09:59:58.000Z'),
        isTrue,
      );
    });

    test('timestamps no parseables -> cuenta nueva (lado seguro)', () {
      expect(looksLikeNewAccount(createdAt: 'no-es-fecha', lastSignInAt: created), isTrue);
      expect(looksLikeNewAccount(createdAt: created, lastSignInAt: 'no-es-fecha'), isTrue);
    });
  });
}
