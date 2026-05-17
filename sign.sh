#!/bin/bash
set -euo pipefail

# ── Znote build + sign helper ───────────────────────────────
#
# Rebuilds the debug binary, refreshes the .app bundle, and signs it with
# the stable Developer ID Application certificate so macOS TCC (Accessibility
# + Input Monitoring) permissions persist across rebuilds.
#
# Usage:
#   ./sign.sh                   Rebuild debug, refresh bundle, sign
#   ./sign.sh release           Rebuild release, refresh bundle, sign
#   ./sign.sh --verify          Just verify the current bundle's signature
# ────────────────────────────────────────────────────────────

IDENTITY="Developer ID Application: naisierding aihemaiti (ZVZ4AP4H2T)"
ENTITLEMENTS="Sources/Znote/Resources/Znote.entitlements"
APP="build/Znote.app"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}▸${NC} $*"; }
ok()   { echo -e "${GREEN}✔${NC} $*"; }
err()  { echo -e "${RED}✖${NC} $*" >&2; }

if [[ "${1:-}" == "--verify" ]]; then
    info "Verifying signature on $APP"
    codesign --display --verbose=2 "$APP" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Signature"
    echo
    spctl --assess --type execute --verbose "$APP" 2>&1 || true
    exit 0
fi

CONFIG="${1:-debug}"
if [[ "$CONFIG" == "release" ]]; then
    BUILD_FLAG="-c release"
    BUILT_BINARY=".build/release/Znote"
else
    BUILD_FLAG=""
    BUILT_BINARY=".build/debug/Znote"
fi

# 1. Build
info "Building ($CONFIG)..."
# shellcheck disable=SC2086
swift build $BUILD_FLAG

# 2. Refresh bundle
info "Refreshing $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILT_BINARY" "$APP/Contents/MacOS/Znote"
cp Sources/Znote/Resources/Info.plist "$APP/Contents/Info.plist"
cp Sources/Znote/Resources/Znote.icns "$APP/Contents/Resources/Znote.icns"

# 3. Sign with stable Developer ID + hardened runtime + entitlements
info "Signing with: $IDENTITY"
codesign --force --deep \
    --options runtime \
    --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP"

# 4. Verify
info "Verifying..."
codesign --verify --verbose=2 "$APP" 2>&1 | head -5
TEAM_ID=$(codesign -dvv "$APP" 2>&1 | grep TeamIdentifier | awk '{print $NF}')
ok "Signed by team $TEAM_ID"
ok "Run: open $APP"
