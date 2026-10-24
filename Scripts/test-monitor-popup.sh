#!/bin/bash
# Builds the native CPU/RAM switching check. Open the app to exercise real popups.
# Timings and run-loop measurements: build/monitor-popup-checks.json.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/SwiftModuleCache build/MonitorPopupChecks.app/Contents/{MacOS,Resources}
xcrun clang -fobjc-arc -target arm64-apple-macosx13.0 -isysroot "$(xcrun --show-sdk-path)" -c MacTools/VirtualWindowDisplay.m -o build/MonitorPopupChecks-bridge.o
SOURCES=(); for SOURCE in MacTools/*.swift; do [[ "$SOURCE" == MacTools/MacToolsApp.swift ]] || SOURCES+=("$SOURCE"); done
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -Onone -whole-module-optimization -module-cache-path build/SwiftModuleCache -D MACTOOLS_PUBLIC_BUILD -import-objc-header MacTools/MacToolsNative.h "${SOURCES[@]}" Tests/MonitorPopupChecks.swift build/MonitorPopupChecks-bridge.o -o build/MonitorPopupChecks.app/Contents/MacOS/MonitorPopupChecks
python3 - <<'PY'
import plistlib
from pathlib import Path
info={'CFBundleExecutable':'MonitorPopupChecks','CFBundleIdentifier':'com.julianfink.MacTools.MonitorPopupChecks','CFBundlePackageType':'APPL','CFBundleName':'MonitorPopupChecks','LSUIElement':False}
Path('build/MonitorPopupChecks.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --deep --sign - build/MonitorPopupChecks.app
