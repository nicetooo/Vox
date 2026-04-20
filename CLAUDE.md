# Vox — Project Instructions

## What is Vox
Native Swift macOS menu bar app. Voice→Text (mlx_whisper), translate selection, screenshot, history. All in one app, no Electron, no Python GUI — Python only as CLI dependency (mlx_whisper, huggingface_hub).

## Build & Run
```bash
# One-shot build + refresh .app + sign with stable Developer ID:
./sign.sh                 # Debug build
./sign.sh release         # Release build
./sign.sh --verify        # Verify the current bundle's signature

# Run:
open build/Vox.app
```

Signing identity: `Developer ID Application: naisierding aihemaiti (ZVZ4AP4H2T)`. Because the identity is stable across rebuilds, **TCC (Accessibility + Input Monitoring) permissions persist** — no re-granting after every `swift build`.

### Manual build (when not using sign.sh)
```bash
swift build                          # Debug
swift build -c release               # Release

cp .build/debug/Vox build/Vox.app/Contents/MacOS/Vox
cp Sources/Vox/Resources/Info.plist build/Vox.app/Contents/Info.plist
cp Sources/Vox/Resources/Vox.icns build/Vox.app/Contents/Resources/Vox.icns
codesign --force --deep --options runtime \
    --sign "Developer ID Application: naisierding aihemaiti (ZVZ4AP4H2T)" \
    --entitlements Sources/Vox/Resources/Vox.entitlements \
    build/Vox.app
```

## Release
```bash
./release.sh v0.1.0                    # Create tag → push → GitHub Actions builds & publishes
./release.sh v0.1.0 -m "First release" # With custom tag message
./release.sh --list                    # List all tags
./release.sh --delete v0.1.0           # Delete tag locally + remotely
```
Script validates version format (`vX.Y.Z`), checks for uncommitted changes, confirms before pushing. GitHub Actions (`.github/workflows/build.yml`) triggers on tag push, builds release, creates GitHub Release with Vox.zip.

## Key Architecture

- **No Python scripts for the app itself** — proper native Swift. Python is external CLI dependency only
- **No extra apps** — one self-contained .app bundle
- **Logging**: Use `log()` function (writes to `/tmp/va.log`), NOT `print()`
- **Python paths**: Auto-discovered at runtime (Framework, Homebrew, /usr/local, /usr/bin), not hardcoded
- **App name**: "Vox" everywhere — bundle name, menu, window titles
- **Bundle identifier**: `com.vox.app`

## Hotkeys (Right-side modifier keys only)
| Gesture | Action |
|---------|--------|
| Right ⌘ hold (>0.3s) | Push-to-talk recording |
| Right ⌘ tap (<0.3s) | Toggle History window |
| Right ⌥ tap | Translate selection (has 0.3s delay for double-tap detection) |
| Right ⌥ double-tap | Screenshot to clipboard |

Key codes: Right ⌘ = keyCode 54, Right ⌥ = keyCode 61. Device flags: NX_DEVICERCMDKEYMASK = 0x10, NX_DEVICERALTKEYMASK = 0x40.

## Whisper Behavior
- **Language detection**: Do NOT force language unless exactly 1 language selected in Settings (after deduplication — zh-Hans and zh-Hant both map to "zh"). Multiple selected → auto-detect → verify with NLLanguageRecognizer → retry with forced language if mismatch.
- **Line breaks**: Always merge multi-line output into single line with spaces
- **Chinese simplified/traditional**: Separate options in Settings. Only simplified → `CFStringTransform("Hant-Hans")`. Only traditional → `CFStringTransform("Hans-Hant")`. Both → no conversion.
- **Silence/hallucination**: Audio level threshold (peak RMS) + minimum duration check

## Translation
- Show result in **floating overlay** (NOT paste in-place). User reads it or clicks Copy.
- Google Translate free endpoint. NLLanguageRecognizer for auto-detection.

## UI Style
- All overlays (recording, translation, history) use **dark floating panel** style: borderless NSPanel, dark background, rounded corners
- History panel: NOT native macOS window — matches overlay theme
- Recording overlay: waveform animation with `sqrt(rms) * 2.5` for dynamic range

## Model Management
- Dropdown for **browsing/managing** (NOT activating). Separate "Activate" button.
- Download shows real byte-level progress via tqdm monkeypatch (must set `disable=False` since stderr is pipe, throttle to 0.3s)
- HuggingFace download via `python3 -c "from huggingface_hub import ..."` with explicit `HOME` and `HF_HOME` env vars
- Most MLX whisper models have `-mlx` suffix. Exceptions: `whisper-large-v3-turbo`, `whisper-tiny`

## Known Constraints
- **Both permissions needed**: CGEventTap needs Input Monitoring (key events) AND Accessibility (simulating Cmd+C/V)
- **NSView `tag` conflict**: Cannot override `tag` with stored property in NSView subclass — use different name (e.g., `index`)
- **SMAppService**: Requires app in /Applications for Launch at Login
- **First launch after signing identity change**: TCC entries are tied to the signing identity. If you ever switch certs (e.g. revoke + recreate), all permissions need to be re-added once. Subsequent rebuilds keep TCC because the identity stays the same.

## GitHub
- **Repo**: `nicetooo/Vox` (SSH: `git@github.com:nicetooo/Vox.git`)
- **Actions**: `.github/workflows/build.yml` — triggers on `v*` tag push + manual dispatch

## Project Structure
```
Sources/Vox/
├── main.swift              # Entry, custom log(), NSApplication setup
├── AppDelegate.swift       # Menu bar, coordinates all services, screenshot
├── KeyMonitor.swift        # CGEventTap: Right ⌘/⌥ tap/hold/double-tap
├── AudioRecorder.swift     # AVAudioEngine, mono mixdown, RMS level
├── WhisperService.swift    # mlx_whisper subprocess, language verify + retry
├── TranslationService.swift # NLLanguageRecognizer + Google Translate
├── SystemIntegration.swift # Simulate Cmd+C/V, clipboard save/restore
├── RecordingOverlay.swift  # Floating waveform animation panel
├── TranslationOverlay.swift # Loading dots → result + Copy button
├── HistoryStore.swift      # SQLite CRUD
├── HistoryWindow.swift     # Dark floating panel: search, date pills, expand rows
├── Settings.swift          # UserDefaults, model list, Python path discovery
├── SettingsWindow.swift    # Language select, model manage, Launch at Login
└── Resources/
    ├── Info.plist           # com.vox.app, LSUIElement=true
    ├── Vox.entitlements     # Hardened runtime entitlements (mic, WhisperKit relaxations)
    └── Vox.icns
```

Root-level scripts:
- `sign.sh` — build + refresh bundle + sign with stable Developer ID
- `release.sh` — tag + push to trigger GitHub Actions release
