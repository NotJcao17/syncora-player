import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncora_player/features/search/search_history_storage.dart';

class InMemorySearchHistoryStorage implements SearchHistoryStorage {
  List<String> _history = [];

  InMemorySearchHistoryStorage([List<String>? initial]) : _history = initial ?? [];

  @override
  Future<List<String>> getHistory() async => List<String>.from(_history);

  @override
  Future<void> saveHistory(List<String> history) async {
    _history = List<String>.from(history);
  }

  @override
  Future<void> clear() async {
    _history = [];
  }
}

void main() {
  group('SearchHistoryNotifier Tests', () {
    late InMemorySearchHistoryStorage storage;
    late ProviderContainer container;

    setUp(() {
      storage = InMemorySearchHistoryStorage(['Rock', 'Pop']);
      container = ProviderContainer(
        overrides: [
          searchHistoryStorageProvider.overrideWithValue(storage),
        ],
      );
    });

    tearDown(() => container.dispose());

    test('loads initial history from storage', () async {
      final notifier = container.read(searchHistoryProvider.notifier);
      await pumpEventQueue();
      expect(container.read(searchHistoryProvider), equals(['Rock', 'Pop']));
    });

    test('addQuery adds to front, deduplicates case-insensitively, and ignores empty', () async {
      final notifier = container.read(searchHistoryProvider.notifier);
      await pumpEventQueue();

      await notifier.addQuery('Jazz');
      expect(container.read(searchHistoryProvider), equals(['Jazz', 'Rock', 'Pop']));

      // Duplicate case-insensitive 'rock' moves to front
      await notifier.addQuery('rock');
      expect(container.read(searchHistoryProvider), equals(['rock', 'Jazz', 'Pop']));

      // Empty string is ignored
      await notifier.addQuery('   ');
      expect(container.read(searchHistoryProvider), equals(['rock', 'Jazz', 'Pop']));
    });

    test('addQuery caps at 20 items', () async {
      final notifier = container.read(searchHistoryProvider.notifier);
      await pumpEventQueue();

      for (int i = 0; i < 25; i++) {
        await notifier.addQuery('Genre $i');
      }

      final history = container.read(searchHistoryProvider);
      expect(history.length, equals(20));
      expect(history.first, equals('Genre 24'));
    });

    test('removeQuery removes specific item', () async {
      final notifier = container.read(searchHistoryProvider.notifier);
      await pumpEventQueue();

      await notifier.removeQuery('Rock');
      expect(container.read(searchHistoryProvider), equals(['Pop']));
    });

    test('clearAll removes all items and clears storage', () async {
      final notifier = container.read(searchHistoryProvider.notifier);
      await pumpEventQueue();

      await notifier.clearAll();
      expect(container.read(searchHistoryProvider), isEmpty);
      expect(await storage.getHistory(), isEmpty);
    });
  });
}
