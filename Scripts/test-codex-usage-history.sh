#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path build/SwiftModuleCache MacTools/CodexUsageHistory.swift Tests/CodexUsageHistoryChecks.swift -o build/codex-usage-history-checks
build/codex-usage-history-checks "$@"
