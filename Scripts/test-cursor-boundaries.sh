#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
xcrun clang -fobjc-arc -c MacTools/VirtualWindowDisplay.m -o build/cursor-boundary-native.o
xcrun swiftc -swift-version 5 -module-cache-path build/SwiftModuleCache -import-objc-header MacTools/MacToolsNative.h MacTools/PinnedWindowCursor.swift Tests/CursorBoundaryChecks.swift build/cursor-boundary-native.o -o build/cursor-boundary-checks
build/cursor-boundary-checks
