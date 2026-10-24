#!/bin/bash
# Builds the isolated native regression app. Open it and exercise both popups;
# streaming/height stress runs against the fixture only. Results: build/popover-layout-checks.json.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache build/PopoverLayoutChecks.app/Contents/{MacOS,Resources}
xcrun clang -fobjc-arc -target arm64-apple-macosx13.0 -isysroot "$(xcrun --show-sdk-path)" -c MacTools/VirtualWindowDisplay.m -o build/PopoverLayoutChecks-bridge.o
SOURCES=(); for SOURCE in MacTools/*.swift; do [[ "$SOURCE" == MacTools/MacToolsApp.swift ]] || SOURCES+=("$SOURCE"); done
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -Onone -whole-module-optimization -module-cache-path build/SwiftModuleCache -D MACTOOLS_PUBLIC_BUILD -import-objc-header MacTools/MacToolsNative.h "${SOURCES[@]}" Tests/PopoverLayoutChecks.swift build/PopoverLayoutChecks-bridge.o -o build/PopoverLayoutChecks.app/Contents/MacOS/PopoverLayoutChecks
cp Tests/Fixtures/codex-app-server.py build/PopoverLayoutChecks.app/Contents/Resources/
ditto Vendor/Mermaid build/PopoverLayoutChecks.app/Contents/Resources/Mermaid
python3 - <<'PY'
import plistlib
from pathlib import Path
info={'CFBundleExecutable':'PopoverLayoutChecks','CFBundleIdentifier':'com.julianfink.MacTools.PopoverLayoutChecks','CFBundlePackageType':'APPL','CFBundleName':'PopoverLayoutChecks','LSUIElement':False}
Path('build/PopoverLayoutChecks.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --deep --sign - build/PopoverLayoutChecks.app
