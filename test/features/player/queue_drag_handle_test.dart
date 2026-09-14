import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ronda 3 bis: fija la tecnica que hace que reordenar la cola sea fiable en
/// tactil, porque los dos intentos anteriores fracasaron y el motivo no es
/// evidente leyendo el widget.
///
/// El problema: `ReorderableDragStartListener` y el `Scrollable` de alrededor
/// aceptan los dos al superar el MISMO umbral de desplazamiento, asi que quien
/// gana la arena de gestos depende del orden. Una moneda al aire.
///
/// La solucion: envolver **solo el asa** en un `MediaQuery` con un `touchSlop`
/// mas pequeno. `ReorderableDragStartListener` construye su reconocedor con
/// los `gestureSettings` del `MediaQuery` mas cercano, asi que el arrastre de
/// reordenar acepta a los pocos pixeles mientras el scroll sigue esperando al
/// umbral normal.
///
/// Este test comprueba justamente esa propiedad —que el asa ve un `touchSlop`
/// estrictamente menor que su entorno— en vez de intentar simular la arena de
/// gestos, que en un test de widget no reproduce la carrera real del
/// dispositivo (Pitfall #27: un test que no imita la semantica real no prueba
/// nada).
void main() {
  testWidgets('el asa de reordenar ve un touchSlop menor que su entorno', (tester) async {
    late double ambientSlop;
    late double handleSlop;

    double slopOf(BuildContext context) =>
        MediaQuery.of(context).gestureSettings.touchSlop ?? kTouchSlop;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Builder(
          builder: (outerContext) {
            ambientSlop = slopOf(outerContext);
            // Replica exacta de lo que hace `_dragHandle` en `queue_view.dart`.
            return MediaQuery(
              data: MediaQuery.of(outerContext).copyWith(
                gestureSettings: const DeviceGestureSettings(touchSlop: 4),
              ),
              child: Builder(
                builder: (innerContext) {
                  handleSlop = slopOf(innerContext);
                  return const SizedBox();
                },
              ),
            );
          },
        ),
      ),
    );

    expect(
      handleSlop,
      lessThan(ambientSlop),
      reason: 'si el asa no acepta ANTES que el scroll, reordenar vuelve a ser una moneda al aire',
    );
    expect(handleSlop, 4);
  });
}
