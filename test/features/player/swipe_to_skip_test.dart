import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/features/player/player_models.dart';
import 'package:syncora_player/features/player/widgets/swipe_to_skip.dart';

void main() {
  group('SwipeToSkip.decide', () {
    SwipeSkipAction decide(double dx, {double velocity = 0, bool prev = true, bool next = true}) =>
        SwipeToSkip.decide(dx: dx, velocity: velocity, width: 300, hasPrevious: prev, hasNext: next);

    test('un arrastre corto no cambia de canción', () {
      expect(decide(-60), SwipeSkipAction.none);
      expect(decide(60), SwipeSkipAction.none);
    });

    test('un roce rápido pero corto tampoco', () {
      expect(decide(-30, velocity: -3000), SwipeSkipAction.none);
    });

    test('arrastrar lo suficiente cambia: izquierda siguiente, derecha anterior', () {
      expect(decide(-120), SwipeSkipAction.next);
      expect(decide(120), SwipeSkipAction.previous);
    });

    test('un lanzamiento con algo de recorrido cambia', () {
      expect(decide(-70, velocity: -1200), SwipeSkipAction.next);
    });

    test('un lanzamiento en sentido contrario al recorrido no cambia', () {
      expect(decide(-70, velocity: 1200), SwipeSkipAction.none);
    });

    test('sin canción de ese lado no hace nada', () {
      expect(decide(-200, next: false), SwipeSkipAction.none);
      expect(decide(200, prev: false), SwipeSkipAction.none);
    });
  });

  group('SwipeToSkip widget', () {
    const current = SyncoraTrack(id: 'c', title: 'Actual');
    const prev = SyncoraTrack(id: 'p', title: 'Anterior');
    const next = SyncoraTrack(id: 'n', title: 'Siguiente');

    Future<({List<String> calls})> pump(WidgetTester tester) async {
      final calls = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 64,
              child: SwipeToSkip(
                current: current,
                previous: prev,
                next: next,
                onTap: () => calls.add('tap'),
                onNext: () => calls.add('next'),
                onPrevious: () => calls.add('previous'),
                itemBuilder: (context, track, isCurrent) => Text(track.title),
                layoutBuilder: (context, area) => area,
              ),
            ),
          ),
        ),
      ));
      return (calls: calls);
    }

    testWidgets('arrastrar a la izquierda pasa a la siguiente', (tester) async {
      final r = await pump(tester);
      await tester.timedDrag(find.text('Actual'), const Offset(-150, 0), const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(r.calls, ['next']);
      expect(find.text('Siguiente'), findsOneWidget);
    });

    testWidgets('arrastrar a la derecha pasa a la anterior', (tester) async {
      final r = await pump(tester);
      await tester.timedDrag(find.text('Actual'), const Offset(150, 0), const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(r.calls, ['previous']);
    });

    testWidgets('un arrastre corto vuelve a su sitio sin cambiar', (tester) async {
      final r = await pump(tester);
      await tester.timedDrag(find.text('Actual'), const Offset(-50, 0), const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(r.calls, isEmpty);
      expect(find.text('Actual'), findsOneWidget);
    });

    testWidgets('un arrastre vertical no cambia de canción', (tester) async {
      final r = await pump(tester);
      await tester.timedDrag(find.text('Actual'), const Offset(-20, 150), const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(r.calls, isEmpty);
    });

    testWidgets('un toque sigue abriendo el reproductor', (tester) async {
      final r = await pump(tester);
      await tester.tap(find.text('Actual'));
      await tester.pumpAndSettle();
      expect(r.calls, ['tap']);
    });
  });
}
