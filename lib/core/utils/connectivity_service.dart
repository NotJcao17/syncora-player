import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Comprueba alcanzabilidad REAL de internet, no solo que exista una interfaz
/// de red activa. `connectivity_plus` reporta lo segundo: en Windows es normal
/// seguir reportando `wifi` con el cable desconectado o sin salida a internet,
/// y en Android el evento de reconexión llega tarde o no llega.
Future<bool> _hasInternet() async {
  try {
    final socket = await Socket.connect(
      '1.1.1.1',
      53,
      timeout: const Duration(seconds: 2),
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
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

  Future<void> check() async {
    // Un chequeo a la vez: el poller y el evento de plataforma pueden caer
    // juntos, y dos sondas simultáneas solo duplican trabajo de red.
    if (checking || closed) return;
    checking = true;
    try {
      final now = await _hasInternet();
      if (closed || now == last) return;
      last = now;
      controller.add(now);
    } finally {
      checking = false;
    }
  }

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
    changeSub?.cancel();
    poller?.cancel();
    controller.close();
  });

  return controller.stream;
});
