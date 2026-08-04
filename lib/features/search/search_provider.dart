import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/apis/deezer_api.dart';
import '../../data/apis/deezer_provider.dart';
import '../../data/models/deezer/deezer_search_result.dart';

class SearchState {
  final String query;
  final DeezerSearchType searchType;
  final bool isLoading;
  final DeezerSearchResult result;
  final String? errorMessage;

  const SearchState({
    this.query = '',
    this.searchType = DeezerSearchType.all,
    this.isLoading = false,
    this.result = const DeezerSearchResult(),
    this.errorMessage,
  });

  SearchState copyWith({
    String? query,
    DeezerSearchType? searchType,
    bool? isLoading,
    DeezerSearchResult? result,
    String? errorMessage,
    bool clearError = false,
  }) {
    return SearchState(
      query: query ?? this.query,
      searchType: searchType ?? this.searchType,
      isLoading: isLoading ?? this.isLoading,
      result: result ?? this.result,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class SearchNotifier extends Notifier<SearchState> {
  Timer? _debounceTimer;

  @override
  SearchState build() {
    ref.onDispose(() {
      _debounceTimer?.cancel();
    });
    return const SearchState();
  }

  void setQuery(String newQuery) {
    if (state.query == newQuery) return;
    _debounceTimer?.cancel();

    final trimmed = newQuery.trim();
    if (trimmed.isEmpty) {
      state = state.copyWith(
        query: '',
        isLoading: false,
        result: const DeezerSearchResult(),
        clearError: true,
      );
      return;
    }

    state = state.copyWith(query: newQuery, isLoading: true, clearError: true);

    // 500ms Debouncer as required by Pitfall #4 & Tarea 1/3
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _performSearch(trimmed, state.searchType);
    });
  }

  void setSearchType(DeezerSearchType type) {
    if (state.searchType == type) return;
    state = state.copyWith(searchType: type);
    if (state.query.trim().isNotEmpty) {
      _performSearch(state.query.trim(), type);
    }
  }

  void retry() {
    if (state.query.trim().isNotEmpty) {
      state = state.copyWith(isLoading: true, clearError: true);
      _performSearch(state.query.trim(), state.searchType);
    }
  }

  Future<void> _performSearch(String query, DeezerSearchType type) async {
    try {
      final deezerApi = ref.read(deezerApiProvider);
      final res = await deezerApi.search(query, type: type);
      if (state.query.trim() != query) return;
      state = state.copyWith(
        isLoading: false,
        result: res,
        clearError: true,
      );
    } catch (e) {
      if (state.query.trim() != query) return;
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Error al conectar con Deezer. Verifica tu conexión.',
      );
    }
  }
}

final searchProvider = NotifierProvider<SearchNotifier, SearchState>(SearchNotifier.new);
