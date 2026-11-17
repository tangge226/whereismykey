#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
"$PROJECT_ROOT/Scripts/build-local.sh" >/dev/null
MODULE_ROOT="$PROJECT_ROOT/.build/local/module"
swiftc -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macosx14.0" \
  -I "$MODULE_ROOT" -L "$MODULE_ROOT" -lWhereKeyCore \
  "$PROJECT_ROOT/Scripts/self-test.swift" \
  -framework Security \
  -o "$PROJECT_ROOT/.build/local/self-test"
TEST_SERVER_DIR="$(mktemp -d "$PROJECT_ROOT/.build/test-server.XXXXXX")"
TEST_READY_FILE="$TEST_SERVER_DIR/port"
TEST_BUNDLE="$TEST_SERVER_DIR/identity/WhereKey.app"
TEST_APP_EXECUTABLE="$TEST_BUNDLE/Contents/MacOS/WhereKeyApp"
TEST_CLI_EXECUTABLE="$TEST_BUNDLE/Contents/Helpers/wherekey"
mkdir -p "$TEST_BUNDLE/Contents/MacOS" "$TEST_BUNDLE/Contents/Helpers"
# Use the real signed CLI and a sealed fixture bundle with a synthetic server.
# Both production identity checks remain enabled; there is no ENV bypass.
cp "$PROJECT_ROOT/.build/local/self-test" "$TEST_APP_EXECUTABLE"
cp "$PROJECT_ROOT/.build/local/wherekey" "$TEST_CLI_EXECUTABLE"
cp "$PROJECT_ROOT/Resources/Info.plist" "$TEST_BUNDLE/Contents/Info.plist"
codesign --force --sign - --options runtime --identifier com.wherekey.mac "$TEST_BUNDLE"
TEST_SOCKET_DIR="$PROJECT_ROOT/.build/test-socket-$$"
python3 "$PROJECT_ROOT/Scripts/test-server.py" 0 "$TEST_READY_FILE" >"$TEST_SERVER_DIR/server.log" 2>&1 &
TEST_SERVER_PID=$!
cleanup() {
  kill "$TEST_SERVER_PID" 2>/dev/null || true
  rm -rf "$TEST_SERVER_DIR"
}
trap cleanup EXIT
for attempt in {1..100}; do
  if [[ -s "$TEST_READY_FILE" ]]; then break; fi
  if ! kill -0 "$TEST_SERVER_PID" 2>/dev/null; then
    cat "$TEST_SERVER_DIR/server.log"
    exit 1
  fi
  sleep 0.1
done
if [[ ! -s "$TEST_READY_FILE" ]]; then
  echo "Fixture server did not become ready within 10 seconds" >&2
  cat "$TEST_SERVER_DIR/server.log"
  exit 1
fi
TEST_PORT="$(cat "$TEST_READY_FILE")"
WHEREKEY_TEST_URL="http://127.0.0.1:$TEST_PORT/" WHEREKEY_TEST_CLI="$TEST_CLI_EXECUTABLE" WHEREKEY_SOCKET_DIR="$TEST_SOCKET_DIR" "$TEST_APP_EXECUTABLE"
"$PROJECT_ROOT/.build/local/wherekey" --help >/dev/null
echo "Build and CLI smoke tests passed"
