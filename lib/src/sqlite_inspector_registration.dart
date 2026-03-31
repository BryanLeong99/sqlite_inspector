import 'dart:convert';
import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

/// VM service extension name (must match the DevTools web client).
const sqliteInspectorExtensionName = 'ext.sqflite_db_inspector.inspect';

/// Alias for SQLite [rowid] in SELECT results (hidden from table UI columns).
const sqliteInspectorRowidKey = '__sqlite_rowid__';

Future<Database> Function()? _getDatabase;

/// Registers the VM service extension the **sqflite_db_inspector** DevTools extension
/// uses to talk to your app’s sqflite [Database].
///
/// **Without this call, the DevTools panel cannot load tables or rows** (you may
/// see errors about the extension not being registered).
///
/// Call **once per process**, as early as practical after
/// [WidgetsFlutterBinding.ensureInitialized], e.g.:
/// `if (!kReleaseMode) { registerSqliteInspector(() => myDb); }`
///
/// [getDatabase] must return the same [Future<Database>] the app uses elsewhere.
/// Each distinct app entrypoint that should work under DevTools must invoke this
/// if it does not share bootstrap code with an entrypoint that already does.
///
/// Safe to call multiple times ([registerExtension] replaces the same name).
/// No-op when [kReleaseMode] is true.
void registerSqliteInspector(Future<Database> Function() getDatabase) {
  if (kReleaseMode) return;
  _getDatabase = getDatabase;
  registerExtension(sqliteInspectorExtensionName, _handle);
}

bool _isSafeSqlIdentifier(String name) => RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(name);

/// DevTools JSON must not include [Uint8List] (blobs).
String _cellToJson(Object? value) {
  if (value == null) return '';
  if (value is Uint8List) return '<BLOB ${value.length} bytes>';
  if (value is num || value is bool) return value.toString();
  if (value is String) return value;
  return value.toString();
}

Future<List<Map<String, Object?>>> _pragmaTableInfo(Database db, String table) =>
    db.rawQuery('PRAGMA table_info("$table")');

Future<Set<String>> _schemaColumnNames(Database db, String table) async {
  final info = await _pragmaTableInfo(db, table);
  return {for (final r in info) '${r['name']}'};
}

/// PK column names in composite-key order (from [PRAGMA table_info] `pk`).
Future<List<String>> _primaryKeyColumnNames(Database db, String table) async {
  final info = await _pragmaTableInfo(db, table);
  final withPk = info
      .map((r) => (name: '${r['name']}', pk: int.tryParse('${r['pk']}') ?? 0))
      .where((e) => e.pk > 0)
      .toList()
    ..sort((a, b) => a.pk.compareTo(b.pk));
  return withPk.map((e) => e.name).toList();
}

bool _columnLooksLikeBlob(String? declaredType) {
  if (declaredType == null) return false;
  return declaredType.toUpperCase().contains('BLOB');
}

Object? _jsonToSqlValue(Object? decoded, {required bool blobColumn}) {
  if (decoded == null) return null;
  if (blobColumn) {
    throw ArgumentError('BLOB columns cannot be edited from sqflite_db_inspector');
  }
  return decoded;
}

Future<String?> _columnDeclaredType(Database db, String table, String column) async {
  final info = await _pragmaTableInfo(db, table);
  for (final r in info) {
    if ('${r['name']}' == column) {
      return '${r['type']}';
    }
  }
  return null;
}

/// Bound parameter for `WHERE col = ?` (helps match INTEGER/REAL stored values).
Object _coerceFilterExactArg(String raw, String? declaredType) {
  final t = declaredType?.toUpperCase() ?? '';
  final s = raw.trim();
  if (t.contains('INT')) {
    final i = int.tryParse(s);
    if (i != null) return i;
  }
  if (t.contains('REAL') || t.contains('FLOA') || t.contains('DOUB')) {
    final d = double.tryParse(s);
    if (d != null) return d;
  }
  if (t.contains('BOOL')) {
    final il = s.toLowerCase();
    if (il == '1' || il == 'true') return 1;
    if (il == '0' || il == 'false') return 0;
  }
  return s;
}

Future<({List<Map<String, Object?>> rows, bool hasRowid})> _queryTableRows({
  required Database db,
  required String table,
  required int limit,
  String? filterColumn,
  String? filterValue,
  String filterMode = 'exact',
}) async {
  final allowed = await _schemaColumnNames(db, table);
  String? whereClause;
  final filterArgs = <Object?>[];

  final col = filterColumn?.trim();
  final val = filterValue?.trim();
  if (col != null && col.isNotEmpty && val != null && val.isNotEmpty) {
    if (!_isSafeSqlIdentifier(col) || !allowed.contains(col)) {
      throw ArgumentError('Invalid filter column: $col');
    }
    final mode = filterMode == 'contains' ? 'contains' : 'exact';
    if (mode == 'contains') {
      whereClause = 'instr(lower(CAST("$col" AS TEXT)), lower(?)) > 0';
      filterArgs.add(val);
    } else {
      final dtype = await _columnDeclaredType(db, table, col);
      whereClause = '"$col" = ?';
      filterArgs.add(_coerceFilterExactArg(val, dtype));
    }
  }

  final suffix = whereClause == null ? ' LIMIT ?' : ' WHERE $whereClause LIMIT ?';
  final argsWithLimit = [...filterArgs, limit];

  try {
    final sql = 'SELECT rowid AS "$sqliteInspectorRowidKey", * FROM "$table"$suffix';
    final rows = await db.rawQuery(sql, argsWithLimit);
    return (rows: rows, hasRowid: true);
  } catch (_) {
    final sql = 'SELECT * FROM "$table"$suffix';
    final rows = await db.rawQuery(sql, argsWithLimit);
    return (rows: rows, hasRowid: false);
  }
}

Future<ServiceExtensionResponse> _handle(String method, Map<String, String> params) async {
  final getDb = _getDatabase;
  if (getDb == null) {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.extensionError,
      jsonEncode({'ok': false, 'error': 'registerSqliteInspector was not called'}),
    );
  }

  final action = params['action'] ?? '';
  try {
    final db = await getDb();
    switch (action) {
      case 'ping':
        return ServiceExtensionResponse.result(jsonEncode({'ok': true}));
      case 'tables':
        final rows = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
        );
        final names = rows.map((r) => r['name'] as String).toList();
        return ServiceExtensionResponse.result(jsonEncode({'ok': true, 'tables': names}));
      case 'schema':
        final table = params['table'] ?? '';
        if (!_isSafeSqlIdentifier(table)) {
          return ServiceExtensionResponse.error(
            ServiceExtensionResponse.invalidParams,
            jsonEncode({'ok': false, 'error': 'Invalid table name'}),
          );
        }
        final info = await _pragmaTableInfo(db, table);
        final encCols = info.map((r) => r.map((k, v) => MapEntry(k, _cellToJson(v)))).toList();
        return ServiceExtensionResponse.result(jsonEncode({'ok': true, 'columns': encCols}));
      case 'select':
        final table = params['table'] ?? '';
        if (!_isSafeSqlIdentifier(table)) {
          return ServiceExtensionResponse.error(
            ServiceExtensionResponse.invalidParams,
            jsonEncode({'ok': false, 'error': 'Invalid table name'}),
          );
        }
        final limit = int.tryParse(params['limit'] ?? '200')?.clamp(1, 2000) ?? 200;
        final filterColumn = params['filterColumn'];
        final filterValue = params['filterValue'];
        final filterMode = params['filterMode'] ?? 'exact';
        try {
          final result = await _queryTableRows(
            db: db,
            table: table,
            limit: limit,
            filterColumn: filterColumn,
            filterValue: filterValue,
            filterMode: filterMode,
          );
          final encoded =
              result.rows.map((r) => r.map((k, v) => MapEntry(k, _cellToJson(v)))).toList();
          return ServiceExtensionResponse.result(
            jsonEncode({'ok': true, 'rows': encoded, 'hasRowid': result.hasRowid}),
          );
        } on ArgumentError catch (e) {
          return ServiceExtensionResponse.error(
            ServiceExtensionResponse.invalidParams,
            jsonEncode({'ok': false, 'error': e.toString()}),
          );
        }
      case 'insert':
        return await _handleInsert(db, params);
      case 'update_cell':
        return await _handleUpdateCell(db, params);
      case 'delete_row':
        return await _handleDeleteRow(db, params);
      default:
        return ServiceExtensionResponse.error(
          ServiceExtensionResponse.invalidParams,
          jsonEncode({'ok': false, 'error': 'Unknown action: $action'}),
        );
    }
  } catch (e, st) {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.extensionError,
      jsonEncode({'ok': false, 'error': e.toString(), 'stack': st.toString()}),
    );
  }
}

Future<ServiceExtensionResponse> _handleInsert(Database db, Map<String, String> params) async {
  final table = params['table'] ?? '';
  if (!_isSafeSqlIdentifier(table)) {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      jsonEncode({'ok': false, 'error': 'Invalid table name'}),
    );
  }
  final raw = params['values'];
  if (raw == null || raw.isEmpty) {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      jsonEncode({'ok': false, 'error': 'Missing values JSON'}),
    );
  }
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      jsonEncode({'ok': false, 'error': 'values must be a JSON object'}),
    );
  }
  final allowed = await _schemaColumnNames(db, table);
  final info = await _pragmaTableInfo(db, table);
  final typeByName = {for (final r in info) '${r['name']}': '${r['type']}'};

  final cols = <String>[];
  final args = <Object?>[];
  for (final entry in decoded.entries) {
    final key = '${entry.key}';
    if (!_isSafeSqlIdentifier(key) || !allowed.contains(key)) continue;
    if (_columnLooksLikeBlob(typeByName[key])) {
      return ServiceExtensionResponse.error(
        ServiceExtensionResponse.invalidParams,
        jsonEncode({'ok': false, 'error': 'Cannot insert into BLOB column $key from inspector'}),
      );
    }
    cols.add('"$key"');
    args.add(_jsonToSqlValue(entry.value, blobColumn: false));
  }
  if (cols.isEmpty) {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      jsonEncode({'ok': false, 'error': 'No valid columns to insert'}),
    );
  }
  final placeholders = List.filled(cols.length, '?').join(',');
  final sql = 'INSERT INTO "$table" (${cols.join(',')}) VALUES ($placeholders)';
  final id = await db.rawInsert(sql, args);
  return ServiceExtensionResponse.result(jsonEncode({'ok': true, 'insertId': id}));
}

Future<ServiceExtensionResponse> _handleUpdateCell(Database db, Map<String, String> params) async {
  final table = params['table'] ?? '';
  if (!_isSafeSqlIdentifier(table)) {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      jsonEncode({'ok': false, 'error': 'Invalid table name'}),
    );
  }
  final raw = params['payload'];
  if (raw == null || raw.isEmpty) {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      jsonEncode({'ok': false, 'error': 'Missing payload JSON'}),
    );
  }
  final payload = jsonDecode(raw);
  if (payload is! Map) {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      jsonEncode({'ok': false, 'error': 'payload must be a JSON object'}),
    );
  }
  final column = '${payload['column'] ?? ''}';
  if (!_isSafeSqlIdentifier(column)) {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      jsonEncode({'ok': false, 'error': 'Invalid column'}),
    );
  }
  if (column == sqliteInspectorRowidKey) {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      jsonEncode({'ok': false, 'error': 'Cannot edit rowid alias'}),
    );
  }
  final allowed = await _schemaColumnNames(db, table);
  if (!allowed.contains(column)) {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      jsonEncode({'ok': false, 'error': 'Unknown column: $column'}),
    );
  }
  final info = await _pragmaTableInfo(db, table);
  String? declaredType;
  for (final r in info) {
    if ('${r['name']}' == column) {
      declaredType = '${r['type']}';
      break;
    }
  }
  if (_columnLooksLikeBlob(declaredType)) {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      jsonEncode({'ok': false, 'error': 'BLOB columns are read-only in inspector'}),
    );
  }

  final value = _jsonToSqlValue(payload['value'], blobColumn: false);

  final hasRowid = payload['hasRowid'] == true;
  final rowidVal = payload['rowid'];
  final pkMap = payload['pk'];
  final List<Object?> whereArgs;
  final String whereClause;

  if (hasRowid && rowidVal != null) {
    final rid = int.tryParse('$rowidVal');
    if (rid == null) {
      return ServiceExtensionResponse.error(
        ServiceExtensionResponse.invalidParams,
        jsonEncode({'ok': false, 'error': 'Invalid rowid'}),
      );
    }
    whereClause = 'rowid = ?';
    whereArgs = [rid];
  } else if (pkMap is Map) {
    final pkNames = await _primaryKeyColumnNames(db, table);
    if (pkNames.isEmpty) {
      return ServiceExtensionResponse.error(
        ServiceExtensionResponse.invalidParams,
        jsonEncode({'ok': false, 'error': 'Table has no primary key; rowid is required'}),
      );
    }
    final parts = <String>[];
    whereArgs = [];
    for (final name in pkNames) {
      if (!_isSafeSqlIdentifier(name)) continue;
      if (!pkMap.containsKey(name)) {
        return ServiceExtensionResponse.error(
          ServiceExtensionResponse.invalidParams,
          jsonEncode({'ok': false, 'error': 'Missing PK value for $name'}),
        );
      }
      parts.add('"$name" = ?');
      whereArgs.add(_jsonToSqlValue(pkMap[name], blobColumn: false));
    }
    if (parts.length != pkNames.length) {
      return ServiceExtensionResponse.error(
        ServiceExtensionResponse.invalidParams,
        jsonEncode({'ok': false, 'error': 'PK mismatch'}),
      );
    }
    whereClause = parts.join(' AND ');
  } else {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      jsonEncode({'ok': false, 'error': 'Provide rowid or pk map'}),
    );
  }

  final sql = 'UPDATE "$table" SET "$column" = ? WHERE $whereClause';
  final n = await db.rawUpdate(sql, [value, ...whereArgs]);
  return ServiceExtensionResponse.result(jsonEncode({'ok': true, 'rowsAffected': n}));
}

Future<ServiceExtensionResponse> _handleDeleteRow(Database db, Map<String, String> params) async {
  final table = params['table'] ?? '';
  if (!_isSafeSqlIdentifier(table)) {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      jsonEncode({'ok': false, 'error': 'Invalid table name'}),
    );
  }
  final raw = params['payload'];
  if (raw == null || raw.isEmpty) {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      jsonEncode({'ok': false, 'error': 'Missing payload JSON'}),
    );
  }
  final payload = jsonDecode(raw);
  if (payload is! Map) {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      jsonEncode({'ok': false, 'error': 'payload must be a JSON object'}),
    );
  }
  final hasRowid = payload['hasRowid'] == true;
  final rowidVal = payload['rowid'];
  final pkMap = payload['pk'];
  final List<Object?> whereArgs;
  final String whereClause;

  if (hasRowid && rowidVal != null) {
    final rid = int.tryParse('$rowidVal');
    if (rid == null) {
      return ServiceExtensionResponse.error(
        ServiceExtensionResponse.invalidParams,
        jsonEncode({'ok': false, 'error': 'Invalid rowid'}),
      );
    }
    whereClause = 'rowid = ?';
    whereArgs = [rid];
  } else if (pkMap is Map) {
    final pkNames = await _primaryKeyColumnNames(db, table);
    if (pkNames.isEmpty) {
      return ServiceExtensionResponse.error(
        ServiceExtensionResponse.invalidParams,
        jsonEncode({'ok': false, 'error': 'Table has no primary key; rowid is required'}),
      );
    }
    final parts = <String>[];
    whereArgs = [];
    for (final name in pkNames) {
      if (!pkMap.containsKey(name)) {
        return ServiceExtensionResponse.error(
          ServiceExtensionResponse.invalidParams,
          jsonEncode({'ok': false, 'error': 'Missing PK value for $name'}),
        );
      }
      parts.add('"$name" = ?');
      whereArgs.add(_jsonToSqlValue(pkMap[name], blobColumn: false));
    }
    whereClause = parts.join(' AND ');
  } else {
    return ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      jsonEncode({'ok': false, 'error': 'Provide rowid or pk map'}),
    );
  }

  final sql = 'DELETE FROM "$table" WHERE $whereClause';
  final n = await db.rawDelete(sql, whereArgs);
  return ServiceExtensionResponse.result(jsonEncode({'ok': true, 'rowsAffected': n}));
}
