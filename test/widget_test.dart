import 'package:flutter_test/flutter_test.dart';

import 'package:alist_android/src/alist_app.dart';

void main() {
  testWidgets('App boots', (WidgetTester tester) async {
    await tester.pumpWidget(const AListApp());
    await tester.pump();

    expect(find.text('AList'), findsWidgets);
  });
}
