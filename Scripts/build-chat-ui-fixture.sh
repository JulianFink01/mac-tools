#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/ChatRenderingQA.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/SwiftModuleCache
xcrun clang -fobjc-arc -target arm64-apple-macosx13.0 -isysroot "$(xcrun --show-sdk-path)" -c MacTools/VirtualWindowDisplay.m -o build/ChatRenderingQA-bridge.o
sources=()
for source in MacTools/*.swift; do [[ "$source" == MacTools/MacToolsApp.swift ]] || sources+=("$source"); done
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -module-cache-path build/SwiftModuleCache -D MACTOOLS_PUBLIC_BUILD -import-objc-header MacTools/MacToolsNative.h "${sources[@]}" Tests/CodexRichUIFixture.swift build/ChatRenderingQA-bridge.o -o "$app/Contents/MacOS/ChatRenderingQA"
ditto Vendor/ChatRenderer "$app/Contents/Resources/ChatRenderer"
ditto Vendor/Mermaid "$app/Contents/Resources/Mermaid"
python3 - "$app" "$PWD" <<'PY'
import plistlib,pathlib,sys
app,root=sys.argv[1:]
(pathlib.Path(app)/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='com.julianfink.MacTools.ChatRenderingQA',CFBundleExecutable='ChatRenderingQA',CFBundleName='MacTools Chat QA',LSEnvironment={'MACTOOLS_QA_ROOT':root})))
PY
codesign --force --sign - "$app"
