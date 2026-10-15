#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
SOURCES=()
for SOURCE in MacTools/*.swift; do
  [[ "$SOURCE" == MacTools/MacToolsApp.swift ]] || SOURCES+=("$SOURCE")
done
xcrun clang -fobjc-arc -target arm64-apple-macosx13.0 -isysroot "$(xcrun --show-sdk-path)" -c MacTools/VirtualWindowDisplay.m -o build/VirtualWindowDisplay-security.o
xcrun swiftc -swift-version 5 -sdk "$(xcrun --show-sdk-path)" -module-cache-path build/SwiftModuleCache \
  -import-objc-header MacTools/MacToolsNative.h "${SOURCES[@]}" build/VirtualWindowDisplay-security.o Tests/SecurityChecks.swift -o build/security-checks
build/security-checks
