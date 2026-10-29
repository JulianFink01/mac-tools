#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
# Compile the exact production representable independently of the full app UI.
python3 - <<'PY'
from pathlib import Path
source = Path('MacTools/CodexChatsView.swift').read_text()
start = source.index('struct CodexComposer: NSViewRepresentable {')
end = source.index('private struct CodexPromptView:', start)
Path('build/CodexComposerUnderTest.swift').write_text('import AppKit\nimport SwiftUI\nimport Combine\n' + source[start:end] + '\n// Attachment storage is outside these synchronization checks.\nenum ChatAttachments { static func save(_ data: Data, extension suffix: String) -> URL? { nil } }\n')
PY
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path build/SwiftModuleCache MacTools/CodexConnection.swift MacTools/CodexDesktopConnection.swift MacTools/CodexComposerModels.swift MacTools/CodexUsageHistory.swift MacTools/CodexStore.swift MacTools/CodexChatImage.swift MacTools/CodexFeaturesView.swift build/CodexComposerUnderTest.swift Tests/CodexComposerSyncChecks.swift -o build/codex-composer-sync-checks
build/codex-composer-sync-checks
