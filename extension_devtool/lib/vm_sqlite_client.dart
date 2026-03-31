import 'dart:convert';

import 'package:devtools_app_shared/utils.dart';
import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:vm_service/vm_service.dart';

/// Must match [sqliteInspectorExtensionName] in package:sqflite_db_inspector.
const _kExtensionMethod = 'ext.sqflite_db_inspector.inspect';

/// Must match [sqliteInspectorRowidKey] in package:sqflite_db_inspector.
const sqliteInspectorRowidColumn = '__sqlite_rowid__';

/// Row filter passed to the VM `select` action.
enum SqliteRowFilterMode {
  /// `WHERE column = ?` (value coerced using schema type when possible).
  exact,

  /// Case-insensitive substring on the column as text (`instr(lower(cast...))`).
  contains,
}

extension on SqliteRowFilterMode {
  String get wireName => switch (this) {
        SqliteRowFilterMode.exact => 'exact',
        SqliteRowFilterMode.contains => 'contains',
      };
}

class TableRowsResult {
  const TableRowsResult({required this.rows, required this.hasRowid});

  final List<Map<String, String>> rows;
  final bool hasRowid;
}

class VmSqliteClient {
  Future<void> _ensureReady() async {
    if (!serviceManager.connectedState.value.connected) {
      throw StateError('Connect a running Flutter app (debug mode).');
    }
    await whenValueNonNull(serviceManager.isolateManager.mainIsolate);
  }

  Future<Map<String, dynamic>> _call(Map<String, String> args) async {
    await _ensureReady();
    final Response response = await serviceManager.callServiceExtensionOnMainIsolate(
      _kExtensionMethod,
      args: args,
    );
    return _decodeResponse(response);
  }

  Map<String, dynamic> _decodeResponse(Response response) {
    final json = response.json;
    if (json == null) {
      return {'ok': false, 'error': 'Empty VM response'};
    }
    if (json['ok'] != null) {
      return Map<String, dynamic>.from(json);
    }
    final value = json['value'];
    if (value is String) {
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return Map<String, dynamic>.from(json);
  }

  Future<void> ping() async {
    final r = await _call({'action': 'ping'});
    if (r['ok'] != true) {
      throw StateError(r['error']?.toString() ?? 'Ping failed');
    }
  }

  Future<List<String>> listTables() async {
    final r = await _call({'action': 'tables'});
    if (r['ok'] != true) {
      throw StateError(r['error']?.toString() ?? 'listTables failed');
    }
    final t = r['tables'];
    if (t is! List) return [];
    return t.cast<String>();
  }

  Future<List<Map<String, dynamic>>> tableSchema(String table) async {
    final r = await _call({'action': 'schema', 'table': table});
    if (r['ok'] != true) {
      throw StateError(r['error']?.toString() ?? 'schema failed');
    }
    final c = r['columns'];
    if (c is! List) return [];
    return c.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<TableRowsResult> tableRows(
    String table, {
    int limit = 200,
    String? filterColumn,
    String? filterValue,
    SqliteRowFilterMode filterMode = SqliteRowFilterMode.exact,
  }) async {
    final args = <String, String>{
      'action': 'select',
      'table': table,
      'limit': '$limit',
      'filterMode': filterMode.wireName,
    };
    final col = filterColumn?.trim();
    final val = filterValue?.trim();
    if (col != null && col.isNotEmpty && val != null && val.isNotEmpty) {
      args['filterColumn'] = col;
      args['filterValue'] = val;
    }
    final r = await _call(args);
    if (r['ok'] != true) {
      throw StateError(r['error']?.toString() ?? 'select failed');
    }
    final rows = r['rows'];
    final list = rows is! List
        ? <Map<String, String>>[]
        : rows.map((e) => (e as Map).map((k, v) => MapEntry('$k', '$v'))).toList();
    final hasRowid = r['hasRowid'] == true;
    return TableRowsResult(rows: list, hasRowid: hasRowid);
  }

  Future<int> insertRow(String table, Map<String, Object?> values) async {
    final r = await _call({
      'action': 'insert',
      'table': table,
      'values': jsonEncode(values),
    });
    if (r['ok'] != true) {
      throw StateError(r['error']?.toString() ?? 'insert failed');
    }
    return (r['insertId'] as num?)?.toInt() ?? 0;
  }

  Future<int> updateCell({
    required String table,
    required String column,
    required Object? value,
    required bool hasRowid,
    int? rowid,
    Map<String, Object?>? pk,
  }) async {
    final payload = <String, Object?>{
      'column': column,
      'value': value,
      'hasRowid': hasRowid,
      'rowid': rowid,
      'pk': pk,
    }..removeWhere((k, v) => v == null);
    final r = await _call({
      'action': 'update_cell',
      'table': table,
      'payload': jsonEncode(payload),
    });
    if (r['ok'] != true) {
      throw StateError(r['error']?.toString() ?? 'update failed');
    }
    return (r['rowsAffected'] as num?)?.toInt() ?? 0;
  }

  Future<int> deleteRow({
    required String table,
    required bool hasRowid,
    int? rowid,
    Map<String, Object?>? pk,
  }) async {
    final payload = <String, Object?>{
      'hasRowid': hasRowid,
      'rowid': rowid,
      'pk': pk,
    }..removeWhere((k, v) => v == null);
    final r = await _call({
      'action': 'delete_row',
      'table': table,
      'payload': jsonEncode(payload),
    });
    if (r['ok'] != true) {
      throw StateError(r['error']?.toString() ?? 'delete failed');
    }
    return (r['rowsAffected'] as num?)?.toInt() ?? 0;
  }
}
