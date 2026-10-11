import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/core/navigation/player_dismiss_shield.dart';

void main() {
  testWidgets('H-R8-7: mientras baja el reproductor, la pantalla de abajo no recibe toques', (tester) async {
    var taps = 0;
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: PlayerDismissShield(
        child: Scaffold(
          body: Center(child: ElevatedButton(onPressed: () => taps++, child: const Text('Canción'))),
        ),
      ),
    ));

    navKey.currentState!.push(PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 300),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, _, _) => const Scaffold(body: SizedBox.expand()),
      transitionsBuilder: (_, animation, _, child) => PlayerDismissShieldWatcher(
        animation: animation,
        child: SlideTransition(
          position: animation.drive(Tween(begin: const Offset(0, 1), end: Offset.zero)),
          child: child,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    navKey.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 120));
    // A mitad de la animación el toque cae en el botón de abajo.
    await tester.tapAt(tester.getCenter(find.text('Canción')), );
    await tester.pump();
    expect(taps, 0);

    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Canción'));
    await tester.pump();
    expect(taps, 1);
    expect(playerDismissShield.value, isFalse);
  });
}
