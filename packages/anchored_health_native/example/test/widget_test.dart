import 'package:flutter_test/flutter_test.dart';

import 'package:anchored_health_native_example/main.dart';

void main() {
  testWidgets('probe app starts', (WidgetTester tester) async {
    await tester.pumpWidget(const ProbeApp());
    expect(find.text('anchored_health_native probe'), findsOneWidget);
  });
}
