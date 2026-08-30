import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Cuántos fallos de alcanzabilidad reales SEGUIDOS hacen falta para declarar
/// "sin internet" en escritorio. Un solo fallo transitorio (ej. un timeout
/// puntual del DNS) no debe tirar a toda la app a modo offline.
const int desktopReachabilityFailureThreshold = 3;

/// Cada cuánto se dispara la sonda de alcanzabilidad en escritorio.
const Duration desktopReachabilityProbeInterval = Duration(seconds: 15);

/// Cuánto se espera por cada intento de conexión de la sonda.
const Duration desktopReachabilityProbeTimeout = Duration(seconds: 4);

/// Endpoints de la sonda de alcanzabilidad de escritorio: resolvers públicos
/// por **IP literal**, nunca por nombre.
///
/// Antes la sonda hacía `InternetAddress.lookup('one.one.one.one')` y eso
/// tenía dos problemas serios, los dos compatibles con el síntoma reportado
/// ("en Windows la detección se duerme tras unos minutos"):
///
/// 1. El cliente DNS de Windows cachea la respuesta, así que un lookup puede
///    seguir "resolviendo bien" con el cable desconectado — la sonda deja de
///    medir alcanzabilidad y pasa a medir el caché del sistema.
/// 2. `Future.timeout` sobre un lookup **no cancela el `getaddrinfo`
///    subyacente**: el hilo del pool de I/O de la VM queda bloqueado hasta
///    que el OS se rinde (decenas de segundos). Una sonda cada 15 s que
///    cuelga va acumulando hilos bloqueados y termina agotando el pool, con
///    lo que la app deja de reaccionar del todo.
///
/// `Socket.connect(..., timeout:)` sí aborta de verdad el intento, y una IP
/// literal no pasa por el resolver ni por su caché.
const List<({String host, int port})> desktopReachabilityProbeEndpoints = [
  (host: '1.1.1.1', port: 53),
  (host: '8.8.8.8', port: 53),
];

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

  /// Evidencia dura de que no hay red (la interfaz se cayó): salta el umbral
  /// y declara offline de inmediato.
  ///
  /// Existe para que el tracker siga siendo la **única** fuente de verdad del
  /// estado. Emitir `false` por fuera dejaría la cuenta en 0 y el siguiente
  /// fallo de sonda devolvería `true`, revirtiendo el offline recién
  /// declarado.
  bool recordHardFailure() {
    _consecutiveFailures = failureThreshold;
    return false;
  }

  int get consecutiveFailures => _consecutiveFailures;
}

/// Máquina de estados de la conectividad en escritorio, aislada de `dart:io`
/// y de `connectivity_plus` para poder testearla.
///
/// Reglas de diseño (todas nacidas de regresiones reales, ver
/// `docs/fases/correcciones_qa_post_fase_7.md` §2.2):
///
/// - **La sonda periódica nunca se apaga.** La versión anterior la gateaba
///   con un flag `interfaceUp` alimentado solo por `connectivity_plus`; si
///   ese stream no emitía el evento de "volvió la interfaz" (algo habitual en
///   Windows), el flag quedaba en `false` para siempre y la sonda se
///   convertía en un no-op permanente: la detección "se dormía" sin retorno.
///   Ahora la interfaz caída es solo una señal rápida para declarar offline
///   ya mismo; quien decide el regreso a online es siempre la sonda.
/// - **Arranque optimista:** nunca se emite `false` como primer valor si hay
///   interfaz, para no bloquear el primer frame esperando la red.
class DesktopConnectivityMonitor {
  DesktopConnectivityMonitor({
    required Future<bool> Function() probe,
    required Stream<bool> interfaceUpEvents,
    Duration probeInterval = desktopReachabilityProbeInterval,
    int failureThreshold = desktopReachabilityFailureThreshold,
  }) : _probe = probe, // ignore: prefer_initializing_formals
       _interfaceUpEvents = interfaceUpEvents, // ignore: prefer_initializing_formals
       _probeInterval = probeInterval, // ignore: prefer_initializing_formals
       _tracker = DesktopReachabilityTracker(
         failureThreshold: failureThreshold,
       );

  final Future<bool> Function() _probe;
  final Stream<bool> _interfaceUpEvents;
  final Duration _probeInterval;
  final DesktopReachabilityTracker _tracker;

  final StreamController<bool> _controller = StreamController<bool>();
  StreamSubscription<bool>? _subscription;
  Timer? _timer;
  bool _probing = false;

  Stream<bool> get stream => _controller.stream.distinct();

  /// Arranca el monitor. [initialInterfaceUp] es el resultado del chequeo
  /// inicial de interfaz (optimista: ante la duda, `true`).
  void start({required bool initialInterfaceUp}) {
    if (initialInterfaceUp) {
      _controller.add(true);
    } else {
      _controller.add(_tracker.recordHardFailure());
    }
    unawaited(_probeAndEmit());

    _subscription = _interfaceUpEvents.listen(
      (up) {
        if (_controller.isClosed) return;
        if (!up) {
          _controller.add(_tracker.recordHardFailure());
        }
        // Suba o baje la interfaz, la sonda es la que decide volver a
        // online: se dispara una ya mismo en vez de esperar al tick.
        unawaited(_probeAndEmit());
      },
      // Sin este handler, un error del stream de plataforma se volvería un
      // error asíncrono no capturado y mataría la detección entera.
      onError: (_) {},
    );

    _timer = Timer.periodic(_probeInterval, (_) => unawaited(_probeAndEmit()));
  }

  Future<void> _probeAndEmit() async {
    // El único gate que queda: no solapar dos sondas. Es seguro porque
    // `_probe` siempre completa (timeout duro), así que el flag no puede
    // quedarse pegado.
    if (_probing || _controller.isClosed) return;
    _probing = true;
    try {
      final reachable = await _probe();
      if (_controller.isClosed) return;
      _controller.add(
        reachable ? _tracker.recordSuccess() : _tracker.recordFailure(),
      );
    } catch (_) {
      if (_controller.isClosed) return;
      _controller.add(_tracker.recordFailure());
    } finally {
      _probing = false;
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _subscription?.cancel();
    _subscription = null;
    if (!_controller.isClosed) await _controller.close();
  }
}

bool _hasInterface(List<ConnectivityResult> results) {
  if (results.isEmpty) return false;
  return !results.contains(ConnectivityResult.none);
}

/// Sonda de alcanzabilidad real para escritorio: abre y cierra una conexión
/// TCP contra un resolver público por IP literal. `false` ante cualquier
/// error — no importa la causa exacta, solo que la red no respondió.
Future<bool> probeDesktopReachability() async {
  for (final endpoint in desktopReachabilityProbeEndpoints) {
    try {
      final socket = await Socket.connect(
        InternetAddress(endpoint.host),
        endpoint.port,
        timeout: desktopReachabilityProbeTimeout,
      );
      socket.destroy();
      return true;
    } catch (_) {
      // Siguiente endpoint: que 1.1.1.1 esté bloqueado en una red concreta
      // no significa que no haya internet.
    }
  }
  return false;
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
  // sonda de alcanzabilidad real.
  var initialInterfaceUp = true;
  try {
    initialInterfaceUp = _hasInterface(await connectivity.checkConnectivity());
  } catch (_) {
    initialInterfaceUp = true;
  }

  final monitor = DesktopConnectivityMonitor(
    probe: probeDesktopReachability,
    interfaceUpEvents: connectivity.onConnectivityChanged.map(_hasInterface),
  );
  ref.onDispose(monitor.dispose);
  monitor.start(initialInterfaceUp: initialInterfaceUp);

  yield* monitor.stream;
});
