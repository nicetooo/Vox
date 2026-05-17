#!/bin/bash
set -euo pipefail

# ── Znote build + sign helper ───────────────────────────────
#
# Rebuilds the binary, refreshes the .app bundle, and signs it with the
# stable Developer ID Application certificate. With --install, also copies
# to /Applications/Znote.app so macOS TCC permissions persist reliably
# across rebuilds (build/Znote.app sometimes confuses tccd's CDHash cache).
#
# Usage:
#   ./sign.sh                   Rebuild debug, refresh bundle, sign
#   ./sign.sh release           Rebuild release, refresh bundle, sign
#   ./sign.sh --install         Same as default + install to /Applications + launch
#   ./sign.sh release --install Release build + install
#   ./sign.sh --verify          Just verify the current bundle's signature
# ────────────────────────────────────────────────────────────

IDENTITY="Developer ID Application: naisierding aihemaiti (ZVZ4AP4H2T)"
ENTITLEMENTS="Sources/Znote/Resources/Znote.entitlements"
APP="build/Znote.app"
INSTALL_PATH="/Applications/Znote.app"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}▸${NC} $*"; }
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✖${NC} $*" >&2; }

# Parse args
CONFIG="debug"
INSTALL=false
VERIFY=false
for arg in "$@"; do
    case "$arg" in
        --verify|-v) VERIFY=true ;;
        --install|-i) INSTALL=true ;;
        release) CONFIG="release" ;;
        debug) CONFIG="debug" ;;
        *) err "Unknown arg: $arg"; echo "See top of sign.sh for usage." >&2; exit 1 ;;
    esac
done

if $VERIFY; then
    info "Verifying signature on $APP"
    codesign --display --verbose=2 "$APP" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|Signature"
    echo
    spctl --assess --type execute --verbose "$APP" 2>&1 || true
    exit 0
fi

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

# 5. Install to /Applications (if requested)
if $INSTALL; then
    info "Quitting any running Znote..."
    pkill -f "/Contents/MacOS/Znote$" 2>/dev/null || true
    sleep 0.5  # let process actually exit so we can rm the bundle

    info "Installing to $INSTALL_PATH..."
    if [[ -d "$INSTALL_PATH" ]]; then
        rm -rf "$INSTALL_PATH"
    fi
    cp -R "$APP" "$INSTALL_PATH"
    # Remove quarantine flag — cp from local sources usually has none, but safe to clear
    xattr -cr "$INSTALL_PATH" 2>/dev/null || true
    ok "Installed: $INSTALL_PATH"

    info "Launching..."
    open "$INSTALL_PATH"
    ok "Launched. TCC permissions should persist across rebuilds now."
else
    ok "Run:     open $APP"
    info "Or:      ./sign.sh --install    (recommended; installs to /Applications + relaunches)"
fi
