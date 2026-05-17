#!/bin/bash
set -euo pipefail

# ── Znote local distributable packaging ───────────────────────
#
# Produces a signed + notarized + stapled Znote.zip that anyone can
# download and double-click on macOS without Gatekeeper complaints.
#
# One-time setup (stores app-specific password in Keychain):
#
#   xcrun notarytool store-credentials "Znote-notary" \
#       --apple-id "nicetooo.a@gmail.com" \
#       --team-id "ZVZ4AP4H2T"
#
#   (enter your App-Specific Password when prompted;
#    generate one at https://appleid.apple.com → Sign-In and Security)
#
# Usage:
#   ./package.sh           Build, sign, notarize, staple → dist/Znote.zip
# ──────────────────────────────────────────────────────────────

APP="build/Znote.app"
NOTARY_PROFILE="Znote-notary"
DIST_DIR="dist"
OUT_ZIP="$DIST_DIR/Znote.zip"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}▸${NC} $*"; }
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✖${NC} $*" >&2; }

# ── 0. Check notary profile exists ──────────────────────────
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null; then
    err "Notary keychain profile '$NOTARY_PROFILE' not found."
    echo ""
    echo "One-time setup — run this first:"
    echo ""
    echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
    echo "      --apple-id \"nicetooo.a@gmail.com\" \\"
    echo "      --team-id \"ZVZ4AP4H2T\""
    echo ""
    echo "When prompted, enter your App-Specific Password."
    echo "Generate one at: https://appleid.apple.com → Sign-In and Security → App-Specific Passwords"
    exit 1
fi

# ── 1. Build release + sign with Developer ID ───────────────
info "Building release and signing..."
./sign.sh release

# ── 2. Zip for notarization submission ──────────────────────
mkdir -p "$DIST_DIR"
SUBMIT_ZIP="$DIST_DIR/Znote-submit.zip"
rm -f "$SUBMIT_ZIP"
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"

# ── 3. Submit to Apple and wait ─────────────────────────────
info "Submitting to Apple for notarization (typically 1-5 min)..."
if ! xcrun notarytool submit "$SUBMIT_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait; then
    err "Notarization failed."
    echo "Fetch the detail log with:"
    echo "  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
    exit 1
fi
ok "Notarization accepted by Apple"
rm -f "$SUBMIT_ZIP"

# ── 4. Staple the ticket onto the .app ──────────────────────
info "Stapling notarization ticket..."
xcrun stapler staple "$APP"
ok "Stapled"

# ── 5. Verify Gatekeeper ────────────────────────────────────
info "Verifying with spctl..."
spctl_out=$(spctl --assess --type execute --verbose "$APP" 2>&1 || true)
echo "$spctl_out"
if echo "$spctl_out" | grep -q "source=Notarized Developer ID"; then
    ok "Gatekeeper will accept this app"
else
    warn "spctl didn't report 'Notarized Developer ID' — review output above"
fi

# ── 6. Produce distributable zip ────────────────────────────
rm -f "$OUT_ZIP"
ditto -c -k --keepParent "$APP" "$OUT_ZIP"
SIZE=$(du -h "$OUT_ZIP" | awk '{print $1}')
ok "Wrote: $OUT_ZIP ($SIZE)"
echo ""
ok "Ready to distribute. Share $OUT_ZIP — users double-click to run."
