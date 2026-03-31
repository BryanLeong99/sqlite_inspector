import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqlite_inspector/sqlite_inspector.dart';

/// Opens (and creates) a tiny demo database used by Flutter DevTools.
Future<Database> _openDemoDb() async {
  final dir = await getApplicationDocumentsDirectory();
  final filePath = p.join(dir.path, 'sqlite_inspector_example.db');
  return openDatabase(
    filePath,
    version: 1,
    onCreate: (db, version) async {
      await db.execute(
        'CREATE TABLE greeting (id INTEGER PRIMARY KEY AUTOINCREMENT, message TEXT NOT NULL)',
      );
      await db.insert('greeting', {'message': 'Hello from sqlite_inspector example'});
    },
  );
}

Database? _cachedDb;

Future<Database> getDemoDatabase() async {
  _cachedDb ??= await _openDemoDb();
  return _cachedDb!;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Required for the sqlite_inspector DevTools extension (debug / profile only).
  if (!kReleaseMode && !kIsWeb) {
    registerSqliteInspector(getDemoDatabase);
  }

  if (!kIsWeb) {
    await getDemoDatabase();
  }

  runApp(const SqliteInspectorExampleApp());
}

class SqliteInspectorExampleApp extends StatelessWidget {
  const SqliteInspectorExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sqlite_inspector example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('sqlite_inspector example')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'This app exists to demonstrate registerSqliteInspector.',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          if (kIsWeb) ...[
            Text(
              'sqflite does not run on web. Run this example on Android, iOS, or desktop.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ] else ...[
            const Text(
              '1. Run in debug mode.\n'
              '2. Open Flutter DevTools for this app.\n'
              '3. Open the sqlite_inspector extension (enable it in devtools_options.yaml if needed).\n'
              '4. You should see table greeting with one row.',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () async {
                final db = await getDemoDatabase();
                await db.insert('greeting', {
                  'message': 'Inserted at ${DateTime.now().toIso8601String()}',
                });
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Inserted another greeting row')),
                  );
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('Insert another row'),
            ),
          ],
        ],
      ),
    );
  }
}
