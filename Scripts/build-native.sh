#!/bin/bash
# Direct local build when Xcode's project driver is unavailable. No system changes.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
BUILD_DIR="$PROJECT_ROOT/build"
APP_PATH="$BUILD_DIR/Release/MacTools.app"
if [[ -n "${MACTOOLS_PRIVATE_CONFIG:-}" ]]; then APP_PATH="$BUILD_DIR/PrivateRelease/MacTools.app"; fi
SAVER_PATH="$APP_PATH/Contents/PlugIns/MacToolsScreenSaver.saver"
SWIFT_COMPILER="$(xcrun --find swiftc)"
SDK_PATH="$(xcrun --show-sdk-path)"
PRIVATE_SWIFT_FLAGS=(-D MACTOOLS_PUBLIC_BUILD)
if [[ -n "${MACTOOLS_PRIVATE_CONFIG:-}" ]]; then
  [[ -f "$MACTOOLS_PRIVATE_CONFIG" ]] || { echo "Private MCP configuration missing" >&2; exit 1; }
  PRIVATE_SWIFT_FLAGS=(-D MACTOOLS_PRIVATE_INTEGRATIONS)
fi
if [[ ! -x Vendor/ClamAV/bin/clamscan ]]; then python3 Scripts/prepare-clamav.py; fi
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$SAVER_PATH/Contents/MacOS" "$BUILD_DIR/SwiftModuleCache"
read -r -a TARGET_ARCHS <<< "${MACTOOLS_BUILD_ARCHS:-arm64 x86_64}"
for TARGET_ARCH in "${TARGET_ARCHS[@]}"; do
  [[ "$TARGET_ARCH" == arm64 || "$TARGET_ARCH" == x86_64 ]] || { echo "Unsupported architecture: $TARGET_ARCH" >&2; exit 1; }
  xcrun clang -fobjc-arc -target "$TARGET_ARCH-apple-macosx13.0" -isysroot "$SDK_PATH" -c MacTools/VirtualWindowDisplay.m -o "$BUILD_DIR/VirtualWindowDisplay-$TARGET_ARCH.o"
  "$SWIFT_COMPILER" -swift-version 5 -sdk "$SDK_PATH" -target "$TARGET_ARCH-apple-macosx13.0" -O -whole-module-optimization \
    -module-cache-path "$BUILD_DIR/SwiftModuleCache" -emit-executable \
    "${PRIVATE_SWIFT_FLAGS[@]}" -import-objc-header MacTools/MacToolsNative.h \
    -o "$BUILD_DIR/MacTools-$TARGET_ARCH" MacTools/*.swift "$BUILD_DIR/VirtualWindowDisplay-$TARGET_ARCH.o"
  "$SWIFT_COMPILER" -swift-version 5 -sdk "$SDK_PATH" -target "$TARGET_ARCH-apple-macosx13.0" -O -whole-module-optimization \
    -module-cache-path "$BUILD_DIR/SwiftModuleCache" -emit-library -Xlinker -bundle \
    -module-name MacToolsScreenSaver -o "$BUILD_DIR/MacToolsScreenSaver-$TARGET_ARCH" MacToolsScreenSaver/*.swift
done
if [[ -n "${MACTOOLS_PRIVATE_CONFIG:-}" ]]; then
  cp "$MACTOOLS_PRIVATE_CONFIG" "$APP_PATH/Contents/Resources/PrivateIntegrations.json"
else
  rm -f "$APP_PATH/Contents/Resources/PrivateIntegrations.json"
fi
APP_BINARIES=(); SAVER_BINARIES=()
for TARGET_ARCH in "${TARGET_ARCHS[@]}"; do APP_BINARIES+=("$BUILD_DIR/MacTools-$TARGET_ARCH"); SAVER_BINARIES+=("$BUILD_DIR/MacToolsScreenSaver-$TARGET_ARCH"); done
if [[ ${#TARGET_ARCHS[@]} -eq 1 ]]; then
  cp "${APP_BINARIES[0]}" "$APP_PATH/Contents/MacOS/MacTools"
  cp "${SAVER_BINARIES[0]}" "$SAVER_PATH/Contents/MacOS/MacToolsScreenSaver"
else
  lipo -create "${APP_BINARIES[@]}" -output "$APP_PATH/Contents/MacOS/MacTools"
  lipo -create "${SAVER_BINARIES[@]}" -output "$SAVER_PATH/Contents/MacOS/MacToolsScreenSaver"
fi
ditto Vendor/ChatRenderer "$APP_PATH/Contents/Resources/ChatRenderer"
ditto Vendor/Mermaid "$APP_PATH/Contents/Resources/Mermaid"
ditto Vendor/Terminal "$APP_PATH/Contents/Resources/Terminal"
ditto Vendor/ClamAV "$APP_PATH/Contents/Resources/ClamAV"
# Static linker archives are build inputs, never runtime resources. Keep source/license material.
find "$APP_PATH/Contents/Resources/ClamAV" -type f -name '*.a' -delete
cp THIRD_PARTY_NOTICES.md "$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.md"
python3 - "$APP_PATH" "$SAVER_PATH" <<'PY'
import plistlib, sys, pathlib, shutil, os
app, saver = map(pathlib.Path, sys.argv[1:])
for source, target, name, identifier, package in [
    ('MacTools/Info.plist', app, 'MacTools', 'com.julianfink.LiveWallpaper', 'APPL'),
    ('MacToolsScreenSaver/Info.plist', saver, 'MacToolsScreenSaver', 'com.julianfink.MacTools.ScreenSaver', 'BNDL')]:
    with open(source, 'rb') as f: info = plistlib.load(f)
    info.update(CFBundleExecutable=name, CFBundleIdentifier=identifier, CFBundlePackageType=package,
                CFBundleDevelopmentRegion='de', CFBundleName='MacTools')
    if package == 'APPL':
        info['CFBundleIconFile'] = 'AppIcon'
        info['MacToolsPrivateBuild'] = bool(os.environ.get('MACTOOLS_PRIVATE_CONFIG'))
    with open(target / 'Contents/Info.plist', 'wb') as f: plistlib.dump(info, f)
# ICNS supports PNG chunks at these Retina-compatible sizes.
import struct
chunks = []
for kind, filename in [('ic07', 'AppIcon-128.png'), ('ic08', 'AppIcon-256.png'),
                       ('ic09', 'AppIcon-512.png'), ('ic10', 'AppIcon-512@2x.png')]:
    data = (pathlib.Path('MacTools/Assets.xcassets/AppIcon.appiconset') / filename).read_bytes()
    chunks.append(kind.encode() + struct.pack('>I', len(data) + 8) + data)
payload = b''.join(chunks)
(app / 'Contents/Resources/AppIcon.icns').write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)
shutil.copyfile('MacTools/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.png', app / 'Contents/Resources/MenuBarIcon.png')
shutil.copyfile('MacTools/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon@2x.png', app / 'Contents/Resources/MenuBarIcon@2x.png')
PY
python3 - "$APP_PATH" <<'CLEAN'
from pathlib import Path
import sys,shutil
app=Path(sys.argv[1])
for relative in ['Contents/Resources/MCP','Contents/Helpers/MacToolsHomeKit.app']:
    path=app/relative
    if path.exists(): shutil.rmtree(path)
CLEAN
ditto MCP/mactools "$APP_PATH/Contents/Resources/MCP"
bash Scripts/sign-app.sh "$APP_PATH"
echo "Built local release: $APP_PATH"
