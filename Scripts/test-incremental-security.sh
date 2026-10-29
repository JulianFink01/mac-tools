#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
cat > build/IncrementalModelStubs.swift <<'SWIFT'
import Foundation
func diskBytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
enum VideoLibraryStore { static let appSupportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-incremental-unused") }
SWIFT
xcrun swiftc -O -swift-version 5 -module-cache-path build/SwiftModuleCache \
  MacTools/DiskScanner.swift MacTools/SecurityScanner.swift MacTools/FileActions.swift MacTools/FileBrowserIndex.swift \
  build/IncrementalModelStubs.swift Tests/IncrementalSecurityChecks.swift -o build/incremental-security-checks
build/incremental-security-checks
