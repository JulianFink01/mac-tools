#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
xcrun clang -fobjc-arc -target arm64-apple-macosx13.0 -isysroot "$(xcrun --show-sdk-path)" -c MacTools/VirtualWindowDisplay.m -o build/TerminalChecks-bridge.o
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path build/SwiftModuleCache -import-objc-header MacTools/MacToolsNative.h MacTools/TerminalProcess.swift Tests/TerminalChecks.swift build/TerminalChecks-bridge.o -framework AppKit -o build/terminal-checks
build/terminal-checks
