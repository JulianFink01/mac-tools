#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path build/SwiftModuleCache MacTools/CodexRichContent.swift Tests/CodexScrollChecks.swift -o build/codex-scroll-checks
build/codex-scroll-checks
