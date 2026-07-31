import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/app.dart';

void main() {
  testWidgets('SyncoraApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: SyncoraApp(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Syncora Player'), findsOneWidget);
    expect(find.text('Ir a Debug Extractor'), findsOneWidget);
  });
}
