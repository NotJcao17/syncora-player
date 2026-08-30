import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Cuántos fallos de alcanzabilidad reales SEGUIDOS hacen falta para declarar
/// "sin internet" en escritorio. Un solo fallo transitorio (ej. un timeout
/// puntual del DNS) no debe tirar a toda la app a modo offline.
const int desktopReachabilityFailureThreshold = 3;

/// Host usado para la sonda de alcanzabilidad real en escritorio. Un lookup
/// DNS es barato y no depende de que un puerto específico esté abierto.
const String desktopReachabilityProbeHost = 'one.one.one.one';

/// Lleva la cuenta de fallos consecutivos de la sonda de alcanzabilidad de
/// escritorio y decide, con esa cuenta, si hay que declarar "sin internet".
///
/// Reglas: hacen falta [failureThreshold] fallos SEGUIDOS para pasar a
/// offline; un solo éxito alcanza para volver a online y resetea la cuenta.
/// Se aísla a propósito de `dart:io`/Riverpod para poder testear la lógica
/// pura sin sockets reales.
class DesktopReachabilityTracker {
  DesktopReachabilityTracker({
    this.failureThreshold = desktopReachabilityFailureThreshold,
  }) : assert(failureThreshold > 0);

  final int failureThreshold;
  int _consecutiveFailures = 0;

  /// Registra una sonda exitosa. Devuelve el estado de conexión resultante
  /// (siempre `true`: un solo éxito basta para volver a online).
  bool recordSuccess() {
    _consecutiveFailures = 0;
    return true;
  }

  /// Registra una sonda fallida. Devuelve el estado de conexión resultante:
  /// sigue `true` mientras no se alcance el umbral, `false` en cuanto se
  /// acumulan [failureThreshold] fallos seguidos.
  bool recordFailure() {
    _consecutiveFailures++;
    return _consecutiveFailures < failureThreshold;
  }

  int get consecutiveFailures => _consecutiveFailures;
}

bool _hasInterface(List<ConnectivityResult> results) {
  if (results.isEmpty) return false;
  return !results.contains(ConnectivityResult.none);
}

/// Sonda de alcanzabilidad real para escritorio: intenta resolver un host
/// público. `false` ante cualquier error (timeout, DNS caído, etc.) — no
/// importa la causa exacta, solo que la red no respondió.
Future<bool> _probeReachability() async {
  try {
    final result = await InternetAddress.lookup(
      desktopReachabilityProbeHost,
    ).timeout(const Duration(seconds: 5));
    return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
  } catch (_) {
    return false;
  }
}

final isConnectedProvider = StreamProvider<bool>((ref) async* {
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    yield true;
    return;
  }

  final connectivity = Connectivity();

  // Android: se confirmó que el chequeo de interfaz de connectivity_plus
  // detecta bien el modo offline ahí. NO tocar este camino — un intento
  // previo de sumar una sonda de alcanzabilidad para todas las plataformas
  // rompió el arranque en Android (falsos offline) y además vaciaba la cola
  // de radio automática (ver syncora_player_controller.dart, guard de
  // `_isConnectedGetter`). El resto de plataformas móviles se trata igual
  // que Android por el mismo motivo: ahí la interfaz de red sí es una señal
  // confiable.
  if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
    try {
      final initial = await connectivity.checkConnectivity();
      yield _hasInterface(initial);
    } catch (_) {
      yield true;
    }
    yield* connectivity.onConnectivityChanged.map(_hasInterface).distinct();
    return;
  }

  // Escritorio: Windows (y el resto de desktop) puede reportar una interfaz
  // wifi/ethernet activa sin salida real a internet, así que se suma una
  // sonda de alcanzabilidad real. Arranque optimista (nunca se emite `false`
  // como primer valor si hay interfaz) y umbral de fallos consecutivos para
  // que un timeout puntual no declare offline en falso.
  final tracker = DesktopReachabilityTracker();
  final controller = StreamController<bool>();
  var interfaceUp = true;
  var probing = false;

  Future<void> probeAndEmit() async {
    if (!interfaceUp || probing || controller.isClosed) return;
    probing = true;
    try {
      final reachable = await _probeReachability();
      if (controller.isClosed) return;
      final connected = reachable
          ? tracker.recordSuccess()
          : tracker.recordFailure();
      controller.add(connected);
    } finally {
      probing = false;
    }
  }

  try {
    final initialResults = await connectivity.checkConnectivity();
    interfaceUp = _hasInterface(initialResults);
  } catch (_) {
    interfaceUp = true;
  }

  if (!interfaceUp) {
    controller.add(false);
  } else {
    // Optimista: se corrige en cuanto termine la primera sonda si hiciera
    // falta, sin bloquear el primer frame a la espera de un lookup DNS.
    controller.add(true);
    unawaited(probeAndEmit());
  }

  final subscription = connectivity.onConnectivityChanged.listen((results) {
    final up = _hasInterface(results);
    interfaceUp = up;
    if (!up) {
      controller.add(false);
    } else {
      unawaited(probeAndEmit());
    }
  });

  final timer = Timer.periodic(
    const Duration(seconds: 15),
    (_) => probeAndEmit(),
  );

  ref.onDispose(() {
    timer.cancel();
    subscription.cancel();
    controller.close();
  });

  yield* controller.stream.distinct();
});
