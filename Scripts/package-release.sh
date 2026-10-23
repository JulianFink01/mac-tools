#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
APP_PATH="${MACTOOLS_PACKAGE_APP:-$PROJECT_ROOT/build/Release/MacTools.app}"
STAGE="$PROJECT_ROOT/build/Distribution"
IMAGE_PATH="$PROJECT_ROOT/build/Release/MacTools-universal.dmg"
python3 - "$APP_PATH" <<'CHECK'
import pathlib,plistlib,sys
app=pathlib.Path(sys.argv[1]);info=plistlib.load(open(app/'Contents/Info.plist','rb'))
if info.get('MacToolsPrivateBuild') or (app/'Contents/Resources/PrivateIntegrations.json').exists():
    raise SystemExit('Private MCP builds cannot be packaged for public distribution. Build the public release without MACTOOLS_PRIVATE_CONFIG.')
CHECK
codesign --verify --deep --strict "$APP_PATH"
mkdir -p "$STAGE"
ditto "$APP_PATH" "$STAGE/MacTools.app"
if [[ ! -L "$STAGE/Applications" ]]; then ln -s /Applications "$STAGE/Applications"; fi
cp README.md "$STAGE/Bitte-lesen.md"
cp THIRD_PARTY_NOTICES.md "$STAGE/THIRD_PARTY_NOTICES.md"
ditto docs "$STAGE/docs"
hdiutil create -volname MacTools -srcfolder "$STAGE" -ov -format UDZO "$IMAGE_PATH"
hdiutil verify "$IMAGE_PATH"
(cd "$(dirname "$IMAGE_PATH")" && shasum -a 256 "$(basename "$IMAGE_PATH")" > "$(basename "$IMAGE_PATH").sha256")
echo "Installationspaket: $IMAGE_PATH"
