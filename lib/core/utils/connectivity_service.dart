import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Comprueba alcanzabilidad REAL de internet, no solo que exista una interfaz
/// de red activa. `connectivity_plus` reporta lo segundo: en Windows es normal
/// seguir reportando `wifi` con el cable desconectado o sin salida a internet,
/// y en Android el evento de reconexión llega tarde o no llega.
/// Se prueban dos hosts y con un timeout holgado: con uno solo y 2s, el arranque
/// en frío del móvil (pila de red todavía levantándose, o un operador que
/// bloquea ese resolver) daba un falso negativo y la app abría en modo offline.
Future<bool> _hasInternet() async {
  const hosts = [('1.1.1.1', 53), ('8.8.8.8', 53)];
  for (final (host, port) in hosts) {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 4),
      );
      socket.destroy();
      return true;
    } catch (_) {
      // Siguiente host.
    }
  }
  return false;
}

final isConnectedProvider = StreamProvider<bool>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    return Stream.value(true);
  }

  final controller = StreamController<bool>();
  final connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? changeSub;
  Timer? poller;
  bool? last;
  var checking = false;
  var closed = false;
  var probeFailures = 0;

  Future<void> check() async {
    // Un chequeo a la vez: el poller y el evento de plataforma pueden caer
    // juntos, y dos sondas simultáneas solo duplican trabajo de red.
    if (checking || closed) return;
    checking = true;
    try {
      // La interfaz de red es la señal primaria: es instantánea y fiable para
      // el caso "no hay red". La sonda solo se usa para el caso contrario
      // (interfaz activa pero sin salida real), y hace falta que falle varias
      // veces seguidas antes de declarar offline — una sola falla puede ser la
      // app recién arrancada, o el sistema suspendiendo sockets en segundo
      // plano, y eso aparecía como una desconexión inexistente.
      List<ConnectivityResult> results;
      try {
        results = await connectivity.checkConnectivity();
      } catch (_) {
        results = const [];
      }

      bool online;
      if (results.isNotEmpty && results.contains(ConnectivityResult.none)) {
        probeFailures = 0;
        online = false;
      } else if (await _hasInternet()) {
        probeFailures = 0;
        online = true;
      } else {
        probeFailures++;
        online = probeFailures < 3;
      }

      if (closed || online == last) return;
      last = online;
      controller.add(online);
    } finally {
      checking = false;
    }
  }

  // Con la app en segundo plano no se sondea: ahi las fallas son del sistema
  // suspendiendo la red, no de la conexion del usuario. Al volver al frente se
  // revisa de inmediato, que es cuando el resultado importa.
  final lifecycle = AppLifecycleListener(
    onResume: () {
      poller ??= Timer.periodic(const Duration(seconds: 5), (_) => check());
      check();
    },
    onPause: () {
      poller?.cancel();
      poller = null;
    },
  );

  // El evento nativo hace que la transición se note al instante cuando SÍ
  // llega; el poller es la red de seguridad para cuando no llega (la causa
  // real de que la reconexión quedara sin detectar y la app no volviera a
  // modo online sin reiniciar).
  changeSub = connectivity.onConnectivityChanged.listen(
    (_) => check(),
    onError: (_) {},
  );
  poller = Timer.periodic(const Duration(seconds: 5), (_) => check());
  check();

  ref.onDispose(() {
    closed = true;
    lifecycle.dispose();
    changeSub?.cancel();
    poller?.cancel();
    controller.close();
  });

  return controller.stream;
});
