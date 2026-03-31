/// SQLite inspector for Flutter DevTools (sqflite).
///
/// **Setup (required):** DevTools only works after you call [registerSqliteInspector]
/// in the running app—typically right after [WidgetsFlutterBinding.ensureInitialized],
/// inside `if (!kReleaseMode) { ... }`. Pass a callback that returns the same
/// `Future<Database>` your app uses. If you add another entrypoint (e.g. a second
/// `main_*.dart`) that does not run that bootstrap, register there too.
///
/// See the **README** in this package for a full checklist and snippet.
library;

export 'src/sqlite_inspector_registration.dart'
    show registerSqliteInspector, sqliteInspectorExtensionName, sqliteInspectorRowidKey;
