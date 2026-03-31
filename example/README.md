# sqlite_inspector example

Minimal Flutter app that:

1. Opens a small **sqflite** database with table `greeting`.
2. Calls **`registerSqliteInspector`** in debug/profile (not web) so the **sqflite_db_inspector** DevTools extension can attach.

This folder is what appears on **pub.dev → Example** after the package is published.

## Run

Use a **mobile or desktop** device (sqflite is not supported on web in this sample):

```bash
cd example
flutter pub get
flutter run
```

## DevTools

1. Run the app in **debug**.
2. Open **Flutter DevTools** for the session.
3. Enable the extension (optional `devtools_options.yaml` in the **host app**):

   ```yaml
   extensions:
     - sqflite_db_inspector: true
   ```

4. Open the **sqflite_db_inspector** panel and browse table `greeting`.
