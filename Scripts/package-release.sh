#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
APP_PATH="$PROJECT_ROOT/build/Release/MacTools.app"
STAGE="$PROJECT_ROOT/build/Distribution"
IMAGE_PATH="$PROJECT_ROOT/build/Release/MacTools-0.2.0-universal.dmg"
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
