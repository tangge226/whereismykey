#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
PACKAGE_ROOT="$PROJECT_ROOT/.build/package"
DIST_ROOT="$PROJECT_ROOT/dist"
APP_BUNDLE="$PACKAGE_ROOT/WhereKey.app"
STAGE_ROOT="$PACKAGE_ROOT/dmg"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PROJECT_ROOT/Resources/Info.plist")"

build_architecture() {
  local architecture="$1"
  local architecture_root="$PACKAGE_ROOT/$architecture"
  local target="$architecture-apple-macosx14.0"
  mkdir -p "$architecture_root/module"

  swiftc -swift-version 5 -O -parse-as-library -sdk "$SDK_PATH" -target "$target" \
    -emit-module -emit-library -static \
    "$PROJECT_ROOT"/Sources/WhereKeyCore/*.swift \
    -module-name WhereKeyCore \
    -emit-module-path "$architecture_root/module/WhereKeyCore.swiftmodule" \
    -framework Security \
    -o "$architecture_root/module/libWhereKeyCore.a"

  swiftc -swift-version 5 -O -parse-as-library -sdk "$SDK_PATH" -target "$target" \
    -I "$architecture_root/module" -L "$architecture_root/module" -lWhereKeyCore \
    "$PROJECT_ROOT"/Sources/WhereKeyApp/*.swift \
    -framework SwiftUI -framework AppKit -framework Security \
    -o "$architecture_root/WhereKeyApp"

  swiftc -swift-version 5 -O -sdk "$SDK_PATH" -target "$target" \
    -I "$architecture_root/module" -L "$architecture_root/module" -lWhereKeyCore \
    "$PROJECT_ROOT/Sources/wherekey/main.swift" \
    -framework Security \
    -o "$architecture_root/wherekey"
}

rm -rf "$PACKAGE_ROOT"
mkdir -p "$PACKAGE_ROOT" "$DIST_ROOT"
build_architecture arm64
build_architecture x86_64

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Helpers" "$APP_BUNDLE/Contents/Resources/Integrations/codex"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
lipo -create "$PACKAGE_ROOT/arm64/WhereKeyApp" "$PACKAGE_ROOT/x86_64/WhereKeyApp" -output "$APP_BUNDLE/Contents/MacOS/WhereKeyApp"
lipo -create "$PACKAGE_ROOT/arm64/wherekey" "$PACKAGE_ROOT/x86_64/wherekey" -output "$APP_BUNDLE/Contents/Helpers/wherekey"
ditto "$PROJECT_ROOT/Integrations/codex/wherekey" "$APP_BUNDLE/Contents/Resources/Integrations/codex/wherekey"
codesign --force --sign - --identifier com.wherekey.cli --requirements "$PROJECT_ROOT/Resources/WhereKeyCLI.requirements" "$APP_BUNDLE/Contents/Helpers/wherekey"
codesign --force --sign - --identifier com.wherekey.mac --requirements "$PROJECT_ROOT/Resources/WhereKey.requirements" "$APP_BUNDLE"

codesign --verify --deep --strict "$APP_BUNDLE"

mkdir -p "$STAGE_ROOT"
ditto "$APP_BUNDLE" "$STAGE_ROOT/WhereKey.app"
cp "$PROJECT_ROOT/Scripts/Install CLI & Codex Skill.command" "$STAGE_ROOT/Install CLI & Codex Skill.command"
chmod +x "$STAGE_ROOT/Install CLI & Codex Skill.command"
ln -s /Applications "$STAGE_ROOT/Applications"
hdiutil create -volname "WhereKey" -srcfolder "$STAGE_ROOT" -ov -format UDZO "$DIST_ROOT/WhereKey-$APP_VERSION-universal.dmg"
(
  cd "$DIST_ROOT"
  shasum -a 256 "WhereKey-$APP_VERSION-universal.dmg" > SHA256SUMS
)
echo "$DIST_ROOT/WhereKey-$APP_VERSION-universal.dmg"
