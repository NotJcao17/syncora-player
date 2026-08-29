import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Comprueba alcanzabilidad REAL de internet, no solo que exista una interfaz
/// de red activa. `connectivity_plus` reporta lo segundo: en Windows es normal
/// seguir reportando `wifi` con el cable desconectado o sin salida a internet,
/// y en Android el evento de reconexión llega tarde o no llega.
/// Se usa una petición HTTPS y no un socket crudo al puerto 53: muchas redes
/// móviles y operadores bloquean el TCP directo a resolvers públicos, así que
/// la sonda anterior fallaba en el teléfono aunque la conexión estuviera
/// perfecta — la app arrancaba creyéndose offline. Este endpoint es el mismo
/// que usa Android para detectar portales cautivos, devuelve 204 sin cuerpo, y
/// viaja por la misma pila HTTP que el resto de la app.
Future<bool> _hasInternet() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    // `connectionTimeout` no cubre la resolución DNS, que en Android puede
    // colgarse bastante más: sin este techo la sonda se quedaba en vuelo y la
    // detección de reconexión no volvía a correr mientras tanto.
    final request = await client
        .headUrl(Uri.parse('https://clients3.google.com/generate_204'))
        .timeout(const Duration(seconds: 6));
    final response = await request.close().timeout(const Duration(seconds: 5));
    await response.drain<void>().timeout(const Duration(seconds: 5));
    return response.statusCode >= 200 && response.statusCode < 400;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
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
      // Una sonda que estaba en vuelo cuando el sistema suspendió la red pudo
      // haber sumado fallos: sin resetear, un único fallo tras volver al frente
      // ya alcanzaba los 3 y declaraba offline, justo en el momento más
      // propenso a falsos negativos.
      probeFailures = 0;
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
