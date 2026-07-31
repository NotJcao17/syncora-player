import 'package:flutter_test/flutter_test.dart';
import 'package:syncora_player/app.dart';

void main() {
  testWidgets('SyncoraApp smoke test', (WidgetTester tester) async {
    // Build SyncoraApp and trigger a frame.
    await tester.pumpWidget(const SyncoraApp());

    // Verify that Syncora Player title is found.
    expect(find.text('Syncora Player'), findsOneWidget);
  });
}
