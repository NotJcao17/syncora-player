import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final isConnectedProvider = StreamProvider<bool>((ref) async* {
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    yield true;
    return;
  }

  final connectivity = Connectivity();

  bool isConnected(List<ConnectivityResult> results) {
    if (results.isEmpty) return false;
    return !results.contains(ConnectivityResult.none);
  }

  try {
    final initial = await connectivity.checkConnectivity();
    yield isConnected(initial);
  } catch (_) {
    yield true;
  }

  yield* connectivity.onConnectivityChanged.map(isConnected).distinct();
});
