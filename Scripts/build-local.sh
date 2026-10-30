#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
BUILD_ROOT="$PROJECT_ROOT/.build/local"
MODULE_ROOT="$BUILD_ROOT/module"
APP_BUNDLE="$PROJECT_ROOT/.build/WhereKey.app"

mkdir -p "$MODULE_ROOT"

swiftc -swift-version 5 -parse-as-library -enable-testing \
  -emit-module -emit-library -static \
  "$PROJECT_ROOT"/Sources/WhereKeyCore/*.swift \
  -module-name WhereKeyCore \
  -emit-module-path "$MODULE_ROOT/WhereKeyCore.swiftmodule" \
  -framework Security \
  -o "$MODULE_ROOT/libWhereKeyCore.a"

swiftc -swift-version 5 -parse-as-library \
  -I "$MODULE_ROOT" -L "$MODULE_ROOT" -lWhereKeyCore \
  "$PROJECT_ROOT"/Sources/WhereKeyApp/*.swift \
  -framework SwiftUI -framework AppKit -framework Security \
  -o "$BUILD_ROOT/WhereKeyApp"

swiftc -swift-version 5 \
  -I "$MODULE_ROOT" -L "$MODULE_ROOT" -lWhereKeyCore \
  "$PROJECT_ROOT/Sources/wherekey/main.swift" \
  -framework Security \
  -o "$BUILD_ROOT/wherekey"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Helpers" "$APP_BUNDLE/Contents/Resources/Integrations/codex"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$BUILD_ROOT/WhereKeyApp" "$APP_BUNDLE/Contents/MacOS/WhereKeyApp"
cp "$BUILD_ROOT/wherekey" "$APP_BUNDLE/Contents/Helpers/wherekey"
ditto "$PROJECT_ROOT/Integrations/codex/wherekey" "$APP_BUNDLE/Contents/Resources/Integrations/codex/wherekey"
codesign --force --sign - --identifier com.wherekey.cli --requirements "$PROJECT_ROOT/Resources/WhereKeyCLI.requirements" "$APP_BUNDLE/Contents/Helpers/wherekey"
codesign --force --sign - --identifier com.wherekey.mac --requirements "$PROJECT_ROOT/Resources/WhereKey.requirements" "$APP_BUNDLE"

echo "$APP_BUNDLE"
