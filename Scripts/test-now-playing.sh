#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path build/SwiftModuleCache MacTools/LocalCommand.swift MacTools/NowPlayingStore.swift Tests/NowPlayingChecks.swift -o build/now-playing-checks
build/now-playing-checks
