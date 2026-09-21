import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/player/listen_tracking.dart';

/// H-S1: el filtro anterior descartaba cualquier avance de posicion mayor a
/// 3 s, incluidos los ticks que simplemente llegaron tarde. Eso perdia
/// minutos reales, y los perdia de forma distinta en Android y en Windows
/// porque sus motores emiten posicion con cadencias distintas -- parte de por
/// que los dos dispositivos nunca mostraban lo mismo.
void main() {
  Duration call({
    required int fromSec,
    required int toSec,
    required bool playing,
    int? sinceLastTickMs,
  }) =>
      naturalListenDelta(
        previousPosition: Duration(seconds: fromSec),
        newPosition: Duration(seconds: toSec),
        playing: playing,
        sinceLastTick: sinceLastTickMs == null ? null : Duration(milliseconds: sinceLastTickMs),
      );

  group('avance natural', () {
    test('un tick rapido normal suma su avance', () {
      expect(call(fromSec: 10, toSec: 11, playing: true, sinceLastTickMs: 1000),
          const Duration(seconds: 1));
    });

    test('un tick que llega 12 s tarde suma los 12 s (la correccion de H-S1)', () {
      // Antes esto devolvia cero y se perdian 12 s de escucha real.
      expect(call(fromSec: 10, toSec: 22, playing: true, sinceLastTickMs: 12000),
          const Duration(seconds: 12));
    });

    test('una suspension larga con el audio sonando cuenta entera', () {
      // Pantalla apagada cinco minutos con el foreground service activo.
      expect(
        naturalListenDelta(
          previousPosition: const Duration(seconds: 30),
          newPosition: const Duration(seconds: 330),
          playing: true,
          sinceLastTick: const Duration(minutes: 5),
        ),
        const Duration(seconds: 300),
      );
    });

    test('sin tick anterior se cae al tope fijo', () {
      expect(call(fromSec: 0, toSec: 2, playing: true), const Duration(seconds: 2));
      expect(call(fromSec: 0, toSec: 30, playing: true), Duration.zero);
    });
  });

  group('lo que NO debe contarse', () {
    test('un seek hacia adelante se ignora', () {
      // De 0:10 a 3:00 en 200 ms de reloj: imposible reproduciendo.
      expect(call(fromSec: 10, toSec: 180, playing: true, sinceLastTickMs: 200), Duration.zero);
    });

    test('un seek hacia atras se ignora', () {
      expect(call(fromSec: 180, toSec: 10, playing: true, sinceLastTickMs: 200), Duration.zero);
    });

    test('en pausa no se acumula nada', () {
      expect(call(fromSec: 10, toSec: 11, playing: false, sinceLastTickMs: 1000), Duration.zero);
    });

    test('la posicion sin cambios no suma', () {
      expect(call(fromSec: 10, toSec: 10, playing: true, sinceLastTickMs: 1000), Duration.zero);
    });

    test('un seek durante un tick tardio sigue siendo un seek', () {
      // El tick tardo 12 s pero la posicion salto 4 minutos: no cabe en el
      // reloj ni con la holgura, asi que es un seek.
      expect(call(fromSec: 10, toSec: 250, playing: true, sinceLastTickMs: 12000), Duration.zero);
    });

    test('el borde: justo dentro y justo fuera de la holgura', () {
      // 10 s de reloj + 2 s de holgura = 12 s admitidos.
      expect(call(fromSec: 0, toSec: 12, playing: true, sinceLastTickMs: 10000),
          const Duration(seconds: 12));
      expect(call(fromSec: 0, toSec: 13, playing: true, sinceLastTickMs: 10000), Duration.zero);
    });
  });
}
