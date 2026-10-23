#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path build/SwiftModuleCache MacTools/CodexConnection.swift MacTools/CodexDesktopConnection.swift MacTools/CodexComposerModels.swift MacTools/CodexStore.swift MacTools/CodexChatImage.swift MacTools/CodexFeaturesView.swift Tests/CodexChecks.swift -o build/codex-checks
build/codex-checks "$@"
