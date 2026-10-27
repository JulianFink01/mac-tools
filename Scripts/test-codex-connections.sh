#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path build/SwiftModuleCache MacTools/CodexConnection.swift MacTools/CodexDesktopConnection.swift Tests/DesktopConnectionChecks.swift -o build/codex-connection-checks
build/codex-connection-checks
python3 Tests/CodexReopenLifecycle.py
