import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_inspector_example/main.dart';

void main() {
  testWidgets('example app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const SqliteInspectorExampleApp());
    expect(find.textContaining('sqflite_db_inspector'), findsWidgets);
  });
}
