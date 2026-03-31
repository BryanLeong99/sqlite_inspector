import 'dart:async';

import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'vm_sqlite_client.dart';

class SqliteInspectorPanel extends StatefulWidget {
  const SqliteInspectorPanel({super.key});

  @override
  State<SqliteInspectorPanel> createState() => _SqliteInspectorPanelState();
}

class _SqliteInspectorPanelState extends State<SqliteInspectorPanel> {
  final _client = VmSqliteClient();
  late final TextEditingController _limitController;
  late final TextEditingController _filterValueController;
  final ScrollController _horizontalScroll = ScrollController();
  final ScrollController _verticalScroll = ScrollController();
  Timer? _timer;

  bool _autoRefresh = true;
  int _rowLimit = 200;
  String? _error;
  bool _loading = false;
  List<String> _tables = [];
  String? _selectedTable;
  List<Map<String, dynamic>> _columns = [];
  List<Map<String, String>> _rows = [];
  bool _hasRowid = true;
  String? _filterColumn;
  SqliteRowFilterMode _filterMode = SqliteRowFilterMode.exact;

  @override
  void initState() {
    super.initState();
    _limitController = TextEditingController(text: '$_rowLimit');
    _filterValueController = TextEditingController();
    serviceManager.connectedState.addListener(_onConnectionChange);
    _onConnectionChange();
  }

  @override
  void dispose() {
    serviceManager.connectedState.removeListener(_onConnectionChange);
    _timer?.cancel();
    _limitController.dispose();
    _filterValueController.dispose();
    _horizontalScroll.dispose();
    _verticalScroll.dispose();
    super.dispose();
  }

  void _onConnectionChange() {
    _timer?.cancel();
    if (serviceManager.connectedState.value.connected) {
      if (_autoRefresh) {
        _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _refresh());
      }
      unawaited(_refresh());
    } else {
      setState(() {
        _tables = [];
        _selectedTable = null;
        _columns = [];
        _rows = [];
        _hasRowid = true;
        _filterColumn = null;
        _filterValueController.clear();
        _error = 'Run the app in debug mode and open DevTools with a VM connection.';
      });
    }
  }

  Future<void> _refresh() async {
    if (!mounted || !serviceManager.connectedState.value.connected) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _client.ping();
      final tables = await _client.listTables();
      if (!mounted) return;
      var selected = _selectedTable;
      if (selected == null || !tables.contains(selected)) {
        selected = tables.isEmpty ? null : tables.first;
      }
      List<Map<String, dynamic>> cols = [];
      List<Map<String, String>> rows = [];
      var hasRowid = true;
      if (selected != null) {
        cols = await _client.tableSchema(selected);
        final result = await _client.tableRows(
          selected,
          limit: _rowLimit,
          filterColumn: _filterColumn,
          filterValue: _filterValueController.text,
          filterMode: _filterMode,
        );
        rows = result.rows;
        hasRowid = result.hasRowid;
      }
      if (!mounted) return;
      setState(() {
        _tables = tables;
        _selectedTable = selected;
        _columns = cols;
        _rows = rows;
        _hasRowid = hasRowid;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _setAutoRefresh(bool value) {
    setState(() => _autoRefresh = value);
    _timer?.cancel();
    if (value && serviceManager.connectedState.value.connected) {
      _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _refresh());
    }
  }

  List<String> get _displayColumnNames {
    final fromSchema = _columns.map((c) => '${c['name']}').where((n) => n != sqliteInspectorRowidColumn).toList();
    if (fromSchema.isNotEmpty) return fromSchema;
    if (_rows.isEmpty) return [];
    return _rows.first.keys.where((k) => k != sqliteInspectorRowidColumn).toList();
  }

  List<String> get _pkColumnNames {
    final withPk = _columns
        .map((c) => (name: '${c['name']}', pk: int.tryParse('${c['pk']}') ?? 0))
        .where((e) => e.pk > 0)
        .toList()
      ..sort((a, b) => a.pk.compareTo(b.pk));
    return withPk.map((e) => e.name).toList();
  }

  Map<String, dynamic>? _columnInfo(String name) {
    for (final c in _columns) {
      if ('${c['name']}' == name) return c;
    }
    return null;
  }

  bool _isBlobColumn(String columnName) {
    final t = _columnInfo(columnName)?['type']?.toString().toUpperCase() ?? '';
    return t.contains('BLOB');
  }

  bool _isNullable(String columnName) {
    final n = _columnInfo(columnName)?['notnull'];
    final v = n is int ? n : int.tryParse('$n') ?? 0;
    return v == 0;
  }

  Object? _parsePayloadValue(String raw) {
    final s = raw.trim();
    if (s == '') return '';
    final il = s.toLowerCase();
    if (il == 'null') return null;
    if (il == 'true') return true;
    if (il == 'false') return false;
    final asInt = int.tryParse(s);
    if (asInt != null) return asInt;
    final asDouble = double.tryParse(s);
    if (asDouble != null) return asDouble;
    return s;
  }

  Object? _coerceForSchema(String columnName, String text, {required bool useNull}) {
    if (useNull) return null;
    final type = _columnInfo(columnName)?['type']?.toString().toUpperCase() ?? '';
    final s = text.trim();
    if (s.isEmpty && _isNullable(columnName)) return null;
    if (type.contains('INT')) {
      final i = int.tryParse(s);
      if (i != null) return i;
    }
    if (type.contains('REAL') || type.contains('FLOA') || type.contains('DOUB')) {
      final d = double.tryParse(s);
      if (d != null) return d;
    }
    if (type.contains('BOOL')) {
      final il = s.toLowerCase();
      if (il == '1' || il == 'true') return 1;
      if (il == '0' || il == 'false') return 0;
    }
    return s;
  }

  Map<String, Object?>? _pkPayload(Map<String, String> row) {
    final keys = _pkColumnNames;
    if (keys.isEmpty) return null;
    final m = <String, Object?>{};
    for (final k in keys) {
      m[k] = _parsePayloadValue(row[k] ?? '');
    }
    return m;
  }

  int? _rowidOf(Map<String, String> row) => int.tryParse(row[sqliteInspectorRowidColumn] ?? '');

  void _toast(String message, {bool error = false}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger != null) {
      messenger.showSnackBar(
        SnackBar(content: Text(message), backgroundColor: error ? Theme.of(context).colorScheme.error : null),
      );
    } else {
      setState(() => _error = message);
    }
  }

  Future<void> _editCell(Map<String, String> row, String column) async {
    if (_selectedTable == null) return;
    if (_isBlobColumn(column)) {
      _toast('BLOB columns are read-only in the inspector.', error: true);
      return;
    }
    final current = row[column] ?? '';
    final nullable = _isNullable(column);
    final controller = TextEditingController(text: current);
    var setNull = current.isEmpty && nullable;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            return AlertDialog(
              title: Text('Edit "$column"'),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (nullable)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Set to NULL'),
                        value: setNull,
                        onChanged: (v) => setLocal(() {
                          setNull = v ?? false;
                        }),
                      ),
                    TextField(
                      controller: controller,
                      enabled: !setNull,
                      maxLines: 3,
                      decoration: const InputDecoration(labelText: 'Value', border: OutlineInputBorder()),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
              ],
            );
          },
        );
      },
    );
    if (ok != true || !mounted) return;

    final value = _coerceForSchema(column, controller.text, useNull: setNull);
    try {
      final rid = _rowidOf(row);
      final pk = _pkPayload(row);
      if (_hasRowid && rid != null) {
        final n = await _client.updateCell(
          table: _selectedTable!,
          column: column,
          value: value,
          hasRowid: true,
          rowid: rid,
        );
        if (n == 0) _toast('No row updated (data may have changed).', error: true);
      } else if (pk != null && pk.length == _pkColumnNames.length) {
        final n = await _client.updateCell(
          table: _selectedTable!,
          column: column,
          value: value,
          hasRowid: false,
          pk: pk,
        );
        if (n == 0) _toast('No row updated (data may have changed).', error: true);
      } else {
        _toast('Cannot identify row (need rowid or primary key).', error: true);
        return;
      }
      _toast('Cell updated.');
      await _refresh();
    } catch (e) {
      _toast(e.toString(), error: true);
    }
  }

  Future<void> _addRow() async {
    if (_selectedTable == null) return;
    final names = _displayColumnNames.where((n) => !_isBlobColumn(n)).toList();
    if (names.isEmpty) {
      _toast('No insertable columns (all BLOB or empty schema).', error: true);
      return;
    }
    final controllers = {for (final n in names) n: TextEditingController()};
    final nullFlags = {for (final n in names) n: false};

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            return AlertDialog(
              title: const Text('Insert row'),
              content: SizedBox(
                width: 480,
                height: 400,
                child: ListView(
                  children: [
                    for (final n in names) ...[
                      if (_isNullable(n))
                        CheckboxListTile(
                          dense: true,
                          title: Text('NULL: $n'),
                          value: nullFlags[n],
                          onChanged: (v) => setLocal(() => nullFlags[n] = v ?? false),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TextField(
                          controller: controllers[n],
                          enabled: !(nullFlags[n] ?? false),
                          decoration: InputDecoration(
                            labelText: n,
                            border: const OutlineInputBorder(),
                            helperText: _columnInfo(n)?['type']?.toString(),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Insert')),
              ],
            );
          },
        );
      },
    );

    if (ok != true || !mounted) {
      for (final c in controllers.values) {
        c.dispose();
      }
      return;
    }

    final values = <String, Object?>{};
    for (final n in names) {
      if (nullFlags[n] == true) {
        values[n] = null;
      } else {
        values[n] = _coerceForSchema(n, controllers[n]!.text, useNull: false);
      }
    }
    for (final c in controllers.values) {
      c.dispose();
    }
    try {
      await _client.insertRow(_selectedTable!, values);
      _toast('Row inserted.');
      await _refresh();
    } catch (e) {
      _toast(e.toString(), error: true);
    }
  }

  Future<void> _deleteRow(Map<String, String> row) async {
    if (_selectedTable == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete row?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: Theme.of(ctx).colorScheme.onError)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      final rid = _rowidOf(row);
      final pk = _pkPayload(row);
      if (_hasRowid && rid != null) {
        await _client.deleteRow(table: _selectedTable!, hasRowid: true, rowid: rid);
      } else if (pk != null && pk.length == _pkColumnNames.length) {
        await _client.deleteRow(table: _selectedTable!, hasRowid: false, pk: pk);
      } else {
        _toast('Cannot identify row (need rowid or primary key).', error: true);
        return;
      }
      _toast('Row deleted.');
      await _refresh();
    } catch (e) {
      _toast(e.toString(), error: true);
    }
  }

  void _onGridPointerSignal(PointerSignalEvent signal) {
    if (signal is! PointerScrollEvent) return;
    if (!HardwareKeyboard.instance.isShiftPressed) return;
    if (!_horizontalScroll.hasClients) return;

    final delta = _horizontalScrollDelta(signal);
    if (delta == 0.0) return;

    final position = _horizontalScroll.position;
    if (!position.hasContentDimensions) return;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;

    GestureBinding.instance.pointerSignalResolver.register(signal, (_) {
      _horizontalScroll.jumpTo(target);
    });
  }

  static double _horizontalScrollDelta(PointerScrollEvent event) {
    final d = event.scrollDelta;
    if (d.dx.abs() >= d.dy.abs()) return d.dx;
    return d.dy;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('Table', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _selectedTable,
                  hint: const Text('Select table'),
                  items: _tables
                      .map((t) => DropdownMenuItem(value: t, child: Text(t, overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: (v) {
                    setState(() {
                      _selectedTable = v;
                      _filterColumn = null;
                      _filterValueController.clear();
                    });
                    unawaited(_refresh());
                  },
                ),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 88,
                child: TextField(
                  decoration: const InputDecoration(labelText: 'Limit', isDense: true),
                  keyboardType: TextInputType.number,
                  controller: _limitController,
                  onSubmitted: (s) {
                    final n = int.tryParse(s)?.clamp(1, 2000) ?? 200;
                    setState(() => _rowLimit = n);
                    _limitController.text = '$_rowLimit';
                    unawaited(_refresh());
                  },
                ),
              ),
              IconButton(
                tooltip: 'Refresh now',
                onPressed: _loading ? null : _refresh,
                icon: _loading
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
              ),
              Tooltip(
                message: !_hasRowid && _pkColumnNames.isEmpty
                    ? 'Cannot insert: table has no rowid and no primary key'
                    : 'Insert row',
                child: FilledButton.tonalIcon(
                  onPressed: (_selectedTable == null || (!_hasRowid && _pkColumnNames.isEmpty)) ? null : _addRow,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add row'),
                ),
              ),
              const SizedBox(width: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Live'),
                  Switch(value: _autoRefresh, onChanged: _setAutoRefresh),
                ],
              ),
            ],
          ),
          if (_selectedTable != null) ...[
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text('Filter', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 168,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Column',
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String?>(
                        isDense: true,
                        isExpanded: true,
                        value: _filterColumn != null && _displayColumnNames.contains(_filterColumn)
                            ? _filterColumn
                            : null,
                        hint: const Text('(none)'),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('(none)'),
                          ),
                          ..._displayColumnNames.map(
                            (n) => DropdownMenuItem(
                              value: n,
                              child: Text(n, overflow: TextOverflow.ellipsis),
                            ),
                          ),
                        ],
                        onChanged: (v) {
                          setState(() => _filterColumn = v);
                          unawaited(_refresh());
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 240,
                  child: TextField(
                    controller: _filterValueController,
                    enabled: _filterColumn != null,
                    decoration: InputDecoration(
                      labelText: 'Value',
                      hintText: _filterColumn == null
                          ? 'Choose a column'
                          : (_filterMode == SqliteRowFilterMode.contains
                              ? 'Substring (case-insensitive)'
                              : 'Exact match'),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => unawaited(_refresh()),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: SegmentedButton<SqliteRowFilterMode>(
                    segments: const [
                      ButtonSegment(
                        value: SqliteRowFilterMode.exact,
                        label: Text('Exact'),
                        tooltip: 'WHERE column = value (typed match)',
                      ),
                      ButtonSegment(
                        value: SqliteRowFilterMode.contains,
                        label: Text('Contains'),
                        tooltip: 'Case-insensitive substring in column text',
                      ),
                    ],
                    selected: {_filterMode},
                    onSelectionChanged: (s) {
                      setState(() => _filterMode = s.first);
                      if (_filterColumn != null && _filterValueController.text.trim().isNotEmpty) {
                        unawaited(_refresh());
                      }
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'Run filter / refresh table',
                  onPressed: _loading ? null : _refresh,
                  icon: const Icon(Icons.search),
                ),
                IconButton(
                  tooltip: 'Clear filter',
                  onPressed: _loading || (_filterColumn == null && _filterValueController.text.isEmpty)
                      ? null
                      : () {
                          setState(() {
                            _filterColumn = null;
                            _filterValueController.clear();
                          });
                          unawaited(_refresh());
                        },
                  icon: const Icon(Icons.filter_alt_off_outlined),
                ),
              ],
            ),
            ),
          ],
          if (!_hasRowid && _pkColumnNames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'This table has no SQLite rowid; edits use the primary key: ${_pkColumnNames.join(', ')}.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    _error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(child: _buildGrid(context)),
        ],
      ),
    );
  }

  Widget _buildGrid(BuildContext context) {
    if (_selectedTable == null) {
      return const Center(child: Text('No tables or database not ready.'));
    }
    final names = _displayColumnNames;
    if (names.isEmpty) {
      return const Center(child: Text('No columns.'));
    }
    return ScrollConfiguration(
      behavior: MaterialScrollBehavior().copyWith(
        dragDevices: {...PointerDeviceKind.values},
      ),
      child: Scrollbar(
        controller: _horizontalScroll,
        thumbVisibility: true,
        scrollbarOrientation: ScrollbarOrientation.bottom,
        notificationPredicate: (ScrollNotification n) =>
            n.depth == 0 && n.metrics.axis == Axis.horizontal,
        child: SingleChildScrollView(
          controller: _horizontalScroll,
          scrollDirection: Axis.horizontal,
          primary: false,
          child: Scrollbar(
            controller: _verticalScroll,
            thumbVisibility: true,
            notificationPredicate: (ScrollNotification n) =>
                n.depth == 0 && n.metrics.axis == Axis.vertical,
            child: SingleChildScrollView(
              controller: _verticalScroll,
              scrollDirection: Axis.vertical,
              primary: false,
              child: Listener(
                onPointerSignal: _onGridPointerSignal,
                child: DataTable(
                  headingRowHeight: 36,
                  dataRowMinHeight: 36,
                  dataRowMaxHeight: 36,
                  horizontalMargin: 8,
                  columnSpacing: 12,
                  columns: [
                    ...names.map(
                      (n) => DataColumn(
                        label: ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 96),
                          child: Text(n, style: const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ),
                    const DataColumn(label: SizedBox(width: 44, child: Icon(Icons.more_horiz, size: 16))),
                  ],
                  rows: _rows.map((row) {
                    return DataRow(
                      cells: [
                        ...names.map(
                          (n) => DataCell(
                            ConstrainedBox(
                              constraints: const BoxConstraints(minWidth: 96),
                              child: Tooltip(
                                message: _isBlobColumn(n)
                                    ? 'BLOB (read-only)'
                                    : 'Tap to edit (Shift+scroll for horizontal)',
                                child: Text(
                                  row[n] ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.2,
                                    color: _isBlobColumn(n)
                                        ? Theme.of(context).disabledColor
                                        : Theme.of(context).colorScheme.primary,
                                    decoration: _isBlobColumn(n) ? null : TextDecoration.underline,
                                    decorationColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
                                  ),
                                ),
                              ),
                            ),
                            onTap: _isBlobColumn(n) ? null : () => _editCell(row, n),
                          ),
                        ),
                        DataCell(
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            tooltip: 'Delete row',
                            onPressed: () => _deleteRow(row),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
