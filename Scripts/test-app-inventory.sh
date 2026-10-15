#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swiftc -swift-version 5 -module-cache-path build/SwiftModuleCache MacTools/AppManagerStore.swift Tests/AppInventoryChecks.swift -o build/app-inventory-checks
build/app-inventory-checks
