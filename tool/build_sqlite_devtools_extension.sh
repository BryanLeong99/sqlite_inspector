#!/usr/bin/env bash
# Builds the DevTools web app and copies output to extension/devtools/build/
#
# Uses flutter/dart on PATH. Override for FVM:
#   FLUTTER="fvm flutter" DART="fvm dart" ./tool/build_sqlite_devtools_extension.sh
set -euo pipefail
PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-flutter}"
DART="${DART:-dart}"
# devtools_extensions spawns `flutter build web`; it must see the same SDK as $FLUTTER.
case "$FLUTTER" in
  */bin/flutter)
    export PATH="$(dirname "$FLUTTER"):${PATH}"
    ;;
esac
case "$DART" in
  */bin/dart)
    export PATH="$(dirname "$DART"):${PATH}"
    ;;
esac
cd "$PKG_ROOT/extension_devtool"
$FLUTTER pub get
$DART run devtools_extensions build_and_copy --source=. --dest=../extension/devtools
echo "Built → $PKG_ROOT/extension/devtools/build/"
