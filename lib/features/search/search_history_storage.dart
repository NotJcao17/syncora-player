import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class SearchHistoryStorage {
  Future<List<String>> getHistory();
  Future<void> saveHistory(List<String> history);
  Future<void> clear();
}

class SecureSearchHistoryStorage implements SearchHistoryStorage {
  static const _key = 'syncora_search_history_v1';
  final FlutterSecureStorage _storage;

  SecureSearchHistoryStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<List<String>> getHistory() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> saveHistory(List<String> history) async {
    try {
      final encoded = jsonEncode(history);
      await _storage.write(key: _key, value: encoded);
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }
}

class SearchHistoryNotifier extends Notifier<List<String>> {
  late final SearchHistoryStorage _storage;

  @override
  List<String> build() {
    _storage = ref.watch(searchHistoryStorageProvider);
    _loadInitial();
    return const [];
  }

  Future<void> _loadInitial() async {
    final list = await _storage.getHistory();
    state = list;
  }

  Future<void> addQuery(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;

    final current = List<String>.from(state);
    current.removeWhere((item) => item.toLowerCase() == trimmed.toLowerCase());
    current.insert(0, trimmed);
    if (current.length > 20) {
      current.removeRange(20, current.length);
    }
    state = current;
    await _storage.saveHistory(current);
  }

  Future<void> removeQuery(String query) async {
    final current = List<String>.from(state);
    current.removeWhere((item) => item.toLowerCase() == query.trim().toLowerCase());
    state = current;
    await _storage.saveHistory(current);
  }

  Future<void> clearAll() async {
    state = const [];
    await _storage.clear();
  }
}

final searchHistoryStorageProvider = Provider<SearchHistoryStorage>((ref) {
  return SecureSearchHistoryStorage();
});

final searchHistoryProvider = NotifierProvider<SearchHistoryNotifier, List<String>>(() {
  return SearchHistoryNotifier();
});
