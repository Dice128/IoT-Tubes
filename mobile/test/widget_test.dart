import 'package:flutter_test/flutter_test.dart';

import 'package:mobile/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const PushUpTrackerApp());

    // Verify the main screen renders with the app title
    expect(find.text('Push-up Tracker'), findsOneWidget);
    expect(find.text('REPS'), findsOneWidget);
  });
}
