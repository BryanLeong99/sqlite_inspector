import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_db_inspector/sqflite_db_inspector.dart';

void main() {
  test('extension name is stable for DevTools client', () {
    expect(sqliteInspectorExtensionName, 'ext.sqflite_db_inspector.inspect');
  });
}
