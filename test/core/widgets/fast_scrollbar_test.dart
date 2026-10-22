import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/widgets/fast_scrollbar.dart';

void main() {
  Future<ScrollController> pumpList(WidgetTester tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FastScrollbar(
          controller: controller,
          enabled: true,
          child: ListView.builder(
            controller: controller,
            itemCount: 200,
            itemBuilder: (_, i) => SizedBox(height: 60, child: Text('fila $i')),
          ),
        ),
      ),
    ));
    // Desplazarse un poco hace aparecer el pulgar.
    controller.jumpTo(100);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return controller;
  }

  Offset thumbCenter(WidgetTester tester, ScrollController controller) {
    final size = tester.getSize(find.byType(Scaffold));
    final track = size.height - 64 - 16;
    final viewport = controller.position.viewportDimension;
    final maxExtent = controller.position.maxScrollExtent;
    final thumbLength = (track * viewport / (viewport + maxExtent)).clamp(56.0, track);
    final top = 64 + (track - thumbLength) * (controller.offset / maxExtent);
    return Offset(size.width - 4, top + thumbLength / 2);
  }

  testWidgets('H-R8-8: un deslizamiento horizontal desde el borde (gesto de atrás) no mueve la lista',
      (tester) async {
    final controller = await pumpList(tester);
    final before = controller.offset;
    final gesture = await tester.startGesture(thumbCenter(tester, controller));
    // Gesto de atrás: hacia la izquierda con algo de temblor vertical.
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(-20, 3));
      await tester.pump();
    }
    await gesture.cancel();
    await tester.pump();
    expect(controller.offset, before);
  });

  testWidgets('arrastrar el pulgar en vertical salta por la lista', (tester) async {
    final controller = await pumpList(tester);
    final before = controller.offset;
    await tester.dragFrom(thumbCenter(tester, controller), const Offset(0, 200));
    await tester.pump();
    expect(controller.offset, greaterThan(before + 1000));
  });

  // Ronda 10: al entrar a una playlist larga (las canciones llegan después y
  // la barra pasa de desactivada a activada) o al girar la pantalla, por un
  // frame se veía un rectángulo gris en el borde derecho: el ErrorWidget de
  // release. Cambiar la estructura del árbol recreaba la lista, el
  // controlador quedaba con dos posiciones y `controller.position` lanzaba.
  Widget harness(ScrollController controller, {required bool enabled, required int count}) => MaterialApp(
        home: Scaffold(
          body: FastScrollbar(
            controller: controller,
            enabled: enabled,
            child: ListView.builder(
              controller: controller,
              itemCount: count,
              itemBuilder: (_, i) => SizedBox(height: 60, child: Text('fila $i')),
            ),
          ),
        ),
      );

  testWidgets('activarse con la lista ya montada no recrea la lista ni lanza', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(harness(controller, enabled: false, count: 0));
    final stateBefore = tester.state(find.byType(Scrollable));
    await tester.pumpWidget(harness(controller, enabled: true, count: 690));
    expect(tester.takeException(), isNull);
    expect(tester.state(find.byType(Scrollable)), same(stateBefore));
    await tester.pumpWidget(harness(controller, enabled: false, count: 690));
    expect(tester.takeException(), isNull);
    expect(tester.state(find.byType(Scrollable)), same(stateBefore));
  });

  testWidgets('un espacio más chico que el pulgar mínimo no lanza', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: 120,
            child: FastScrollbar(
              controller: controller,
              enabled: true,
              child: ListView.builder(
                controller: controller,
                itemCount: 200,
                itemBuilder: (_, i) => SizedBox(height: 60, child: Text('fila $i')),
              ),
            ),
          ),
        ),
      ),
    ));
    controller.jumpTo(100);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
