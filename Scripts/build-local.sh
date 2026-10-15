#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacTools"
BUILD_DIR="$PROJECT_ROOT/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
EXPORT_DIR="$BUILD_DIR/Release"
APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"

cd "$PROJECT_ROOT"
python3 Scripts/prepare-clamav.py


mkdir -p "$BUILD_DIR/SwiftModuleCache"
swift -module-cache-path "$BUILD_DIR/SwiftModuleCache" Tools/generate_app_icon.swift

xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  build


mkdir -p "$EXPORT_DIR"
ditto "$APP_PATH" "$EXPORT_DIR/$APP_NAME.app"

bash Scripts/sign-app.sh "$EXPORT_DIR/$APP_NAME.app"

echo "Built local release:"
echo "$EXPORT_DIR/$APP_NAME.app"
echo ""
echo "For a stable Start at Login setup, move the app to /Applications and launch it from there once."
