import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_inspector/sqlite_inspector.dart';

void main() {
  test('VM extension name matches DevTools client', () {
    expect(sqliteInspectorExtensionName, 'ext.sqlite_inspector.inspect');
  });
}
