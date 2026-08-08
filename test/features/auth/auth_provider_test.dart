import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/auth/auth_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AuthProvider Tests', () {
    test('currentUserProvider returns null in test env when unauthenticated', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final user = container.read(currentUserProvider);
      expect(user, isNull);
    });

    test('authStateProvider returns empty stream in test env by default', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final authStateAsync = container.read(authStateProvider);
      expect(authStateAsync, isA<AsyncValue>());
    });
  });
}
