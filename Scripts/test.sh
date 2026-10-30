#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
"$PROJECT_ROOT/Scripts/build-local.sh" >/dev/null
MODULE_ROOT="$PROJECT_ROOT/.build/local/module"
swiftc -swift-version 5 \
  -I "$MODULE_ROOT" -L "$MODULE_ROOT" -lWhereKeyCore \
  "$PROJECT_ROOT/Scripts/self-test.swift" \
  -framework Security \
  -o "$PROJECT_ROOT/.build/local/self-test"
TEST_PORT=$((18000 + $$ % 1000))
TEST_SOCKET_DIR="$PROJECT_ROOT/.build/test-socket-$$"
python3 -m http.server "$TEST_PORT" --bind 127.0.0.1 --directory "$PROJECT_ROOT/.build" >/dev/null 2>&1 &
TEST_SERVER_PID=$!
trap 'kill "$TEST_SERVER_PID" 2>/dev/null || true' EXIT
sleep 0.2
WHEREKEY_TEST_URL="http://127.0.0.1:$TEST_PORT/" WHEREKEY_SOCKET_DIR="$TEST_SOCKET_DIR" "$PROJECT_ROOT/.build/local/self-test"
"$PROJECT_ROOT/.build/local/wherekey" --help >/dev/null
echo "Build and CLI smoke tests passed"
