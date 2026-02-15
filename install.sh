#!/bin/bash
set -e

# =============================================================================
# VoiceAssistant Installer
# macOS menu bar app: voice-to-text + translation
# Requires: Apple Silicon Mac, macOS 14+
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}==>${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}!${NC} $1"; }
fail()  { echo -e "${RED}✗ $1${NC}"; exit 1; }

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║        VoiceAssistant Installer          ║"
echo "║   Voice → Text  |  Translate Selection   ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# --- Check macOS ---
[[ "$(uname)" == "Darwin" ]] || fail "This app only runs on macOS."

# --- Check Apple Silicon ---
if [[ "$(uname -m)" != "arm64" ]]; then
    fail "VoiceAssistant requires Apple Silicon (M1/M2/M3/M4). MLX does not run on Intel Macs."
fi
ok "Apple Silicon detected"

# --- Check macOS version (need 14+) ---
MACOS_VERSION=$(sw_vers -productVersion | cut -d. -f1)
if [[ "$MACOS_VERSION" -lt 14 ]]; then
    fail "macOS 14 (Sonoma) or later required. You have $(sw_vers -productVersion)."
fi
ok "macOS $(sw_vers -productVersion)"

# --- Check Xcode Command Line Tools ---
if ! xcode-select -p &>/dev/null; then
    info "Installing Xcode Command Line Tools (needed to compile)..."
    xcode-select --install
    echo ""
    warn "Xcode CLT installation started. Please complete it and re-run this script."
    exit 0
fi
ok "Xcode Command Line Tools"

# --- Find or install Python 3 ---
PYTHON=""
for p in \
    /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 \
    /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 \
    /Library/Frameworks/Python.framework/Versions/3.11/bin/python3 \
    /opt/homebrew/bin/python3 \
    /usr/local/bin/python3; do
    if [[ -x "$p" ]]; then
        # Check version is 3.9+
        PY_VER=$("$p" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "0.0")
        PY_MAJOR=$(echo "$PY_VER" | cut -d. -f1)
        PY_MINOR=$(echo "$PY_VER" | cut -d. -f2)
        if [[ "$PY_MAJOR" -ge 3 && "$PY_MINOR" -ge 9 ]]; then
            PYTHON="$p"
            break
        fi
    fi
done

if [[ -z "$PYTHON" ]]; then
    info "Python 3.9+ not found. Installing via Homebrew..."
    if ! command -v brew &>/dev/null; then
        info "Installing Homebrew first..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    brew install python@3.13
    PYTHON="/opt/homebrew/bin/python3"
fi

PY_VER=$("$PYTHON" --version 2>&1)
ok "Python: $PY_VER ($PYTHON)"

# --- Install pip packages ---
info "Installing mlx-whisper and huggingface_hub..."
"$PYTHON" -m pip install --upgrade --quiet mlx-whisper huggingface_hub
ok "Python packages installed"

# Check mlx_whisper is accessible
PY_BIN_DIR=$(dirname "$PYTHON")
MLX_WHISPER="$PY_BIN_DIR/mlx_whisper"
if [[ ! -x "$MLX_WHISPER" ]]; then
    # Try pip show to find it
    MLX_WHISPER=$("$PYTHON" -c "import shutil; print(shutil.which('mlx_whisper') or '')" 2>/dev/null)
fi
if [[ -x "$MLX_WHISPER" ]]; then
    ok "mlx_whisper: $MLX_WHISPER"
else
    warn "mlx_whisper binary not found in PATH — the app will try to locate it at runtime"
fi

# --- Determine install directory ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if running from the cloned repo
if [[ -f "$SCRIPT_DIR/Package.swift" && -d "$SCRIPT_DIR/Sources/VoiceAssistant" ]]; then
    INSTALL_DIR="$SCRIPT_DIR"
    ok "Building from current directory: $INSTALL_DIR"
else
    # Clone the repo
    INSTALL_DIR="$HOME/.local/share/VoiceAssistant"
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        info "Updating existing installation..."
        cd "$INSTALL_DIR"
        git pull
    else
        info "Cloning VoiceAssistant..."
        mkdir -p "$(dirname "$INSTALL_DIR")"
        git clone https://github.com/nicetooo/VoiceAssistant.git "$INSTALL_DIR"
    fi
fi

cd "$INSTALL_DIR"

# --- Build ---
info "Building VoiceAssistant (this may take a moment)..."
swift build 2>&1 | tail -3
ok "Build complete"

# --- Create .app bundle ---
info "Creating app bundle..."
APP_DIR="build/VoiceAssistant.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp .build/debug/VoiceAssistant "$APP_DIR/Contents/MacOS/VoiceAssistant"
cp Sources/VoiceAssistant/Resources/Info.plist "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null
ok "App bundle created"

# --- Install to /Applications ---
info "Installing to /Applications..."
if [[ -d "/Applications/VoiceAssistant.app" ]]; then
    rm -rf "/Applications/VoiceAssistant.app"
fi
cp -R "$APP_DIR" "/Applications/VoiceAssistant.app"
# Remove quarantine flag so macOS doesn't block it
xattr -cr "/Applications/VoiceAssistant.app" 2>/dev/null || true
ok "Installed to /Applications/VoiceAssistant.app"

# --- Done ---
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║         Installation Complete!           ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo -e "${YELLOW}IMPORTANT: Grant these permissions before first use:${NC}"
echo ""
echo "  1. System Settings → Privacy & Security → Accessibility"
echo "     → Click '+' → Add VoiceAssistant from /Applications"
echo ""
echo "  2. System Settings → Privacy & Security → Input Monitoring"
echo "     → Click '+' → Add VoiceAssistant from /Applications"
echo ""
echo "  3. System Settings → Privacy & Security → Microphone"
echo "     → Allow VoiceAssistant"
echo ""
echo -e "${GREEN}Usage:${NC}"
echo "  Hold Right ⌘ — Voice to text (push-to-talk)"
echo "  Tap Right ⌥  — Translate selected text"
echo ""
echo -e "Launch: ${BLUE}open /Applications/VoiceAssistant.app${NC}"
echo ""
