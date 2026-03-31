import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:flutter/material.dart';

import 'sqlite_inspector_panel.dart';

void main() {
  runApp(const SqliteInspectorDevToolApp());
}

class SqliteInspectorDevToolApp extends StatelessWidget {
  const SqliteInspectorDevToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const DevToolsExtension(
      child: SqliteInspectorPanel(),
    );
  }
}
