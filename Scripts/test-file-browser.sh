#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
xcrun swiftc -swift-version 5 -sdk "$(xcrun --show-sdk-path)" -module-cache-path build/SwiftModuleCache \
  MacTools/DiskScanner.swift MacTools/FileBrowserIndex.swift Tests/FileBrowserChecks.swift -o build/file-browser-checks
build/file-browser-checks
