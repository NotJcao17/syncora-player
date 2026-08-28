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

  // `distinct()` antes solo se aplicaba al stream de cambios: el chequeo
  // inicial y la primera emisión de `onConnectivityChanged` (el plugin
  // reemite el estado actual apenas alguien se suscribe) podían duplicar el
  // mismo valor. Este `lastEmitted` deduplica sobre TODO el stream fusionado,
  // no solo la mitad de él.
  bool? lastEmitted;

  try {
    final initial = await connectivity.checkConnectivity();
    lastEmitted = isConnected(initial);
    yield lastEmitted;
  } catch (_) {
    lastEmitted = true;
    yield true;
  }

  // Un único glitch transitorio del plugin nativo (`onConnectivityChanged`
  // emitiendo un error en vez de un valor) mataba el generador `async*`
  // entero -- sin este `handleError`, el provider quedaba en estado de error
  // para siempre y la app dejaba de detectar desconexión/reconexión hasta
  // reiniciar. Ahora el error se ignora (no se reemite nada) y el stream
  // sigue vivo para el próximo cambio real de conectividad.
  await for (final results in connectivity.onConnectivityChanged.handleError((_) {})) {
    final next = isConnected(results);
    if (next == lastEmitted) continue;
    lastEmitted = next;
    yield next;
  }
});
