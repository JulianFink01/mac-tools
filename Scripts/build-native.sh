#!/bin/bash
# Direct local build when Xcode's project driver is unavailable. No system changes.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
BUILD_DIR="$PROJECT_ROOT/build"
APP_PATH="$BUILD_DIR/Release/MacTools.app"
SAVER_PATH="$APP_PATH/Contents/PlugIns/MacToolsScreenSaver.saver"
SWIFT_COMPILER="$(xcrun --find swiftc)"
SDK_PATH="$(xcrun --show-sdk-path)"
if [[ ! -x Vendor/ClamAV/bin/clamscan ]]; then python3 Scripts/prepare-clamav.py; fi
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$SAVER_PATH/Contents/MacOS" "$BUILD_DIR/SwiftModuleCache"
for TARGET_ARCH in arm64 x86_64; do
  xcrun clang -fobjc-arc -target "$TARGET_ARCH-apple-macosx13.0" -isysroot "$SDK_PATH" -c MacTools/VirtualWindowDisplay.m -o "$BUILD_DIR/VirtualWindowDisplay-$TARGET_ARCH.o"
  "$SWIFT_COMPILER" -swift-version 5 -sdk "$SDK_PATH" -target "$TARGET_ARCH-apple-macosx13.0" -O \
    -module-cache-path "$BUILD_DIR/SwiftModuleCache" -emit-executable \
    -import-objc-header MacTools/MacToolsNative.h \
    -o "$BUILD_DIR/MacTools-$TARGET_ARCH" MacTools/*.swift "$BUILD_DIR/VirtualWindowDisplay-$TARGET_ARCH.o"
  "$SWIFT_COMPILER" -swift-version 5 -sdk "$SDK_PATH" -target "$TARGET_ARCH-apple-macosx13.0" -O \
    -module-cache-path "$BUILD_DIR/SwiftModuleCache" -emit-library -Xlinker -bundle \
    -module-name MacToolsScreenSaver -o "$BUILD_DIR/MacToolsScreenSaver-$TARGET_ARCH" MacToolsScreenSaver/*.swift
done
lipo -create "$BUILD_DIR/MacTools-arm64" "$BUILD_DIR/MacTools-x86_64" -output "$APP_PATH/Contents/MacOS/MacTools"
lipo -create "$BUILD_DIR/MacToolsScreenSaver-arm64" "$BUILD_DIR/MacToolsScreenSaver-x86_64" -output "$SAVER_PATH/Contents/MacOS/MacToolsScreenSaver"
ditto Vendor/ClamAV "$APP_PATH/Contents/Resources/ClamAV"
cp THIRD_PARTY_NOTICES.md "$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.md"
python3 - "$APP_PATH" "$SAVER_PATH" <<'PY'
import plistlib, sys, pathlib, shutil
app, saver = map(pathlib.Path, sys.argv[1:])
for source, target, name, identifier, package in [
    ('MacTools/Info.plist', app, 'MacTools', 'com.julianfink.LiveWallpaper', 'APPL'),
    ('MacToolsScreenSaver/Info.plist', saver, 'MacToolsScreenSaver', 'com.julianfink.MacTools.ScreenSaver', 'BNDL')]:
    with open(source, 'rb') as f: info = plistlib.load(f)
    info.update(CFBundleExecutable=name, CFBundleIdentifier=identifier, CFBundlePackageType=package,
                CFBundleDevelopmentRegion='de', CFBundleName='MacTools')
    if package == 'APPL': info['CFBundleIconFile'] = 'AppIcon'
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
bash Scripts/sign-app.sh "$APP_PATH"
echo "Built local release: $APP_PATH"
