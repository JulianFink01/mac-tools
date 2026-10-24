#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
cat > build/VolumeModelStubs.swift <<'SWIFT'
import Foundation
enum VideoLibraryStore { static let appSupportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-volume-unused") }
@MainActor final class AutomaticScans { static let shared = AutomaticScans(); func runNow() {}; func cancelCombined() {} }
SWIFT
xcrun swiftc -swift-version 5 -module-cache-path build/SwiftModuleCache \
  MacTools/DiskScanner.swift MacTools/DiskScanCache.swift MacTools/FileBrowserIndex.swift \
  MacTools/DiskScanStore.swift MacTools/FileActions.swift MacTools/SecurityScanner.swift MacTools/DiskVolumeStore.swift \
  build/VolumeModelStubs.swift Tests/VolumeScanChecks.swift -o build/volume-scan-checks
build/volume-scan-checks
