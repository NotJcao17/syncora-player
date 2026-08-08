import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final isConnectedProvider = StreamProvider<bool>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    return Stream.value(true);
  }
  return Connectivity().onConnectivityChanged.map((results) {
    if (results.isEmpty) return false;
    return !results.contains(ConnectivityResult.none);
  });
});
