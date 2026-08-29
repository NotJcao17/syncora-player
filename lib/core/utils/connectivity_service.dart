import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final isConnectedProvider = StreamProvider<bool>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    return Stream.value(true);
  }

  final connectivity = Connectivity();

  bool isConnected(List<ConnectivityResult> results) {
    if (results.isEmpty) return false;
    return !results.contains(ConnectivityResult.none);
  }

  Stream<bool> merged() async* {
    try {
      yield isConnected(await connectivity.checkConnectivity());
    } catch (_) {
      yield true;
    }

    // Un único glitch transitorio del plugin nativo (`onConnectivityChanged`
    // emitiendo un error en vez de un valor) mataba el generador `async*`
    // entero -- sin este `handleError`, el provider quedaba en estado de
    // error para siempre y la app dejaba de detectar desconexión/reconexión
    // hasta reiniciar. Ahora el error se ignora (no se reemite nada) y el
    // stream sigue vivo para el próximo cambio real de conectividad.
    yield* connectivity.onConnectivityChanged.map(isConnected).handleError((_) {});
  }

  // Ítem 6 (QA, regresión): la versión anterior deduplicaba a mano con una
  // variable `lastEmitted` comparada evento a evento -- funcionalmente
  // equivalente a lo que ya hace `distinct()`, pero manual y sin ningún test
  // que lo cubriera; se sospecha (sin poder reproducirlo fuera de un
  // dispositivo real) que esa lógica terminó comiéndose transiciones reales
  // en vez de solo duplicados. `distinct()` es la primitiva estándar de
  // `Stream` para exactamente este problema -- se aplica sobre la secuencia
  // fusionada completa (chequeo inicial + cambios), así que sigue evitando
  // la doble emisión del mismo valor sin lógica propia que pueda tener un
  // bug de orden/comparación.
  return merged().distinct();
});
