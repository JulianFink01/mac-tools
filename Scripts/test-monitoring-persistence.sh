#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
SOURCES=()
for SOURCE in MacTools/*.swift; do
  [[ "$SOURCE" == MacTools/MacToolsApp.swift ]] || SOURCES+=("$SOURCE")
done
xcrun clang -fobjc-arc -target arm64-apple-macosx13.0 -isysroot "$(xcrun --show-sdk-path)" -c MacTools/VirtualWindowDisplay.m -o build/VirtualWindowDisplay-checks.o
xcrun swiftc -swift-version 5 -module-cache-path build/SwiftModuleCache -import-objc-header MacTools/MacToolsNative.h "${SOURCES[@]}" build/VirtualWindowDisplay-checks.o Tests/MonitoringPersistenceChecks.swift -o build/monitoring-persistence-checks
build/monitoring-persistence-checks
