#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="build/QA/WallpaperQA.app"
mkdir -p "$TARGET/Contents/MacOS" build/SwiftModuleCache
SOURCES=()
for SOURCE in MacTools/*.swift; do
  [[ "$SOURCE" == MacTools/MacToolsApp.swift ]] || SOURCES+=("$SOURCE")
done
xcrun clang -fobjc-arc -target arm64-apple-macosx13.0 -isysroot "$(xcrun --show-sdk-path)" -c MacTools/VirtualWindowDisplay.m -o build/VirtualWindowDisplay-checks.o
xcrun swiftc -swift-version 5 -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macosx13.0 -module-cache-path build/SwiftModuleCache -import-objc-header MacTools/MacToolsNative.h "${SOURCES[@]}" build/VirtualWindowDisplay-checks.o Tests/WallpaperResumeChecks.swift -o "$TARGET/Contents/MacOS/WallpaperQA"
python3 - "$TARGET" <<'PY'
import plistlib,pathlib,sys
path=pathlib.Path(sys.argv[1])/'Contents/Info.plist'
path.write_bytes(plistlib.dumps(dict(CFBundleExecutable='WallpaperQA',CFBundleIdentifier='com.julianfink.MacTools.WallpaperQA',CFBundleName='WallpaperQA',CFBundlePackageType='APPL',LSMinimumSystemVersion='13.0')))
PY
IDENTITY="$(cat build/code-signing-identity.txt)"
codesign --force --sign "$IDENTITY" "$TARGET"
