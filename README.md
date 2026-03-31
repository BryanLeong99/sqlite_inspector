# sqlite_inspector

Flutter **DevTools extension** plus a **VM service** hook to inspect **sqflite** in any Flutter app: browse tables, column metadata, row preview, filters, and CRUD (debug/profile only).

## Required: register the VM hook in your app

The DevTools UI **does nothing** until your running app calls **`registerSqliteInspector`**. That registers the VM service extension DevTools talks to.

**You should:**

1. Add `sqlite_inspector` to `dependencies` (see below).
2. After **`WidgetsFlutterBinding.ensureInitialized()`**, call **`registerSqliteInspector`** once per process (wrapped in **`!kReleaseMode`** is recommended). Pass a callback that returns the **`Future<Database>`** your app actually uses for sqflite—not a second connection unless intentional.
3. If the project has **multiple entrypoints** (e.g. `main_development.dart`, `main_staging.dart`) that **do not** share the same bootstrap code path, register in **each** path that can run under DevTools. Otherwise that flavor will show errors like the extension not being registered or no data.

**Release builds:** `registerSqliteInspector` returns immediately in release (`kReleaseMode`); no DevTools traffic in production.

See also the dartdoc on `registerSqliteInspector` in the package API (IDE hover).

**On pub.dev**, the **Example** tab shows the [`example/`](example/) app (same code as in the published tarball).

## Add to your app

```yaml
dependencies:
  sqlite_inspector: ^0.1.0
```

Git while developing:

```yaml
dependencies:
  sqlite_inspector:
    git:
      url: https://github.com/your-username/sqlite_inspector.git
      ref: main
```

### Registration snippet

After `WidgetsFlutterBinding.ensureInitialized()`:

```dart
import 'package:flutter/foundation.dart';
import 'package:sqlite_inspector/sqlite_inspector.dart';

if (!kReleaseMode) {
  registerSqliteInspector(() => yourOpenDatabase());
}
```

Replace `yourOpenDatabase` with your real opener (e.g. `() => LocalDatabase.instance.database`). It must return the same `Future<Database>` the rest of the app uses.

## DevTools

Enable the extension (optional `devtools_options.yaml`):

```yaml
extensions:
  - sqlite_inspector: true
```

## Build the embedded web UI

Required before `pub publish`, or when `extension/devtools/build/` is empty:

```bash
chmod +x tool/build_sqlite_devtools_extension.sh
./tool/build_sqlite_devtools_extension.sh
```

With FVM:

```bash
FLUTTER="fvm flutter" DART="fvm dart" ./tool/build_sqlite_devtools_extension.sh
```

## Own GitHub repo + pub.dev

1. Use this folder as the repository root.
2. Replace `your-username` in `pubspec.yaml` and `extension/devtools/config.yaml`.
3. Run the build script, then `dart pub publish --dry-run` / `dart pub publish`.

See [CHANGELOG.md](CHANGELOG.md).

## License

BSD-3-Clause — [LICENSE](LICENSE).
