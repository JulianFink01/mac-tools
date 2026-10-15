#!/bin/bash
# Keep one signing identity across local updates so macOS permissions can persist.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:?App-Pfad fehlt}"
SIGNING_IDENTITY="${MACTOOLS_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" && -f "$PROJECT_ROOT/build/code-signing-identity.txt" ]]; then
  SIGNING_IDENTITY="$(cat "$PROJECT_ROOT/build/code-signing-identity.txt")"
fi
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Hinweis: Ad-hoc-Signierung. macOS-Freigaben können bei jedem Update erneut nötig sein." >&2
fi
codesign --force --sign "$SIGNING_IDENTITY" "$APP_PATH/Contents/PlugIns/MacToolsScreenSaver.saver"
codesign --force --sign "$SIGNING_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
codesign --display --requirements - "$APP_PATH" 2>&1
