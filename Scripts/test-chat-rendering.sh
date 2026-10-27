#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache
python3 - <<'PY'
import hashlib,json,pathlib
root=pathlib.Path('Vendor/ChatRenderer')
for name,digest in json.loads((root/'versions.json').read_text())['files'].items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest, name
print('PASS: pinned renderer library and font hashes')
PY
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path build/SwiftModuleCache MacTools/CodexRichContent.swift Tests/CodexRenderingChecks.swift -o build/chat-rendering-checks
build/chat-rendering-checks
