#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
cat > build/StateModelStubs.swift <<'SWIFT'
import Foundation
enum VideoLibraryStore { static let appSupportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-state-unused") }
SWIFT
xcrun swiftc -O -swift-version 5 -module-cache-path build/SwiftModuleCache \
  MacTools/DiskScanner.swift MacTools/DiskScanCache.swift MacTools/FileBrowserIndex.swift \
  MacTools/DiskScanStore.swift MacTools/FileActions.swift MacTools/SecurityScanner.swift \
  build/StateModelStubs.swift Tests/RemovalStateChecks.swift -o build/removal-state-checks
build/removal-state-checks
