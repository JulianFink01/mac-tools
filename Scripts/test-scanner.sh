#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
xcrun swiftc -swift-version 5 -sdk "$(xcrun --show-sdk-path)" \
  -module-cache-path build/SwiftModuleCache MacTools/DiskScanner.swift Tests/ScannerChecks.swift -o build/scanner-checks
build/scanner-checks
