import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/widgets/playing_indicator.dart';

void main() {
  List<double> heights(WidgetTester tester) => [
        for (final c in tester.widgetList<Container>(
            find.descendant(of: find.byType(PlayingIndicator), matching: find.byType(Container))))
          c.constraints?.maxHeight ?? 0,
      ];

  testWidgets('H-R8-15: el indicador de "sonando" no anima a 60 fps', (tester) async {
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: PlayingIndicator(color: Colors.white)),
    ));
    // Sin animaciones por frame (la versión anterior tenía un ticker continuo).
    expect(SchedulerBinding.instance.transientCallbackCount, 0);

    final before = heights(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(heights(tester), before, reason: 'entre pasos no se redibuja');
    await tester.pump(const Duration(milliseconds: 120));
    expect(heights(tester), isNot(before), reason: 'cada 200 ms cambia');
    expect(SchedulerBinding.instance.transientCallbackCount, 0);
  });
}
