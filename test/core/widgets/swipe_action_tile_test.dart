import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/widgets/swipe_action_tile.dart';

void main() {
  late int right;
  late int left;
  late int taps;

  Future<void> pump(WidgetTester tester) async {
    right = 0;
    left = 0;
    taps = 0;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            for (var i = 0; i < 30; i++)
              SwipeActionTile(
                key: ValueKey(i),
                onSwipeRight: () => right++,
                onSwipeLeft: () => left++,
                child: InkWell(onTap: () => taps++, child: SizedBox(height: 60, child: Text('fila $i'))),
              ),
          ],
        ),
      ),
    ));
  }

  testWidgets('deslizar a la derecha desde el borde izquierdo confirma la acción', (tester) async {
    await pump(tester);
    await tester.dragFrom(const Offset(20, 30), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(right, 1);
  });

  testWidgets('deslizar a la derecha desde el centro no hace nada', (tester) async {
    await pump(tester);
    await tester.dragFrom(const Offset(200, 30), const Offset(180, 0));
    await tester.pumpAndSettle();
    expect(right, 0);
  });

  testWidgets('un scroll diagonal no encola', (tester) async {
    await pump(tester);
    await tester.dragFrom(const Offset(20, 300), const Offset(60, -250));
    await tester.pumpAndSettle();
    expect(right, 0);
  });

  testWidgets('un fling corto a la derecha no alcanza el umbral', (tester) async {
    await pump(tester);
    await tester.flingFrom(const Offset(20, 30), const Offset(80, 0), 2000);
    await tester.pumpAndSettle();
    expect(right, 0);
  });

  testWidgets('deslizar a la izquierda quita desde cualquier punto', (tester) async {
    await pump(tester);
    await tester.dragFrom(const Offset(300, 30), const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(left, 1);
  });

  testWidgets('un toque sigue llegando a la fila', (tester) async {
    await pump(tester);
    await tester.tap(find.text('fila 0'));
    await tester.pump();
    expect(taps, 1);
  });
}
