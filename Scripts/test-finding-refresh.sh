#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
cat > build/FindingModelStubs.swift <<'SWIFT'
import Foundation
func diskBytes(_ value:Int64)->String { ByteCountFormatter.string(fromByteCount:value,countStyle:.file) }
enum VideoLibraryStore { static let appSupportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-finding-unused") }
SWIFT
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path build/SwiftModuleCache \
 MacTools/DiskScanner.swift MacTools/SecurityScanner.swift MacTools/FileActions.swift MacTools/FileBrowserIndex.swift \
 build/FindingModelStubs.swift Tests/FindingRefreshChecks.swift -o build/finding-refresh-checks
build/finding-refresh-checks
