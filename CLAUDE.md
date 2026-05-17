# Znote — Project Instructions

## What is Znote
Native Swift macOS menu bar app. Voice→Text (WhisperKit, CoreML), translate selection, screenshot, history. All in one app, no Electron, no Python GUI — fully native Swift.

## Build & Run
```bash
# One-shot build + refresh .app + sign with stable Developer ID:
./sign.sh                 # Debug build
./sign.sh release         # Release build
./sign.sh --verify        # Verify the current bundle's signature

# Run:
open build/Znote.app
```

Signing identity: `Developer ID Application: naisierding aihemaiti (ZVZ4AP4H2T)`. Because the identity is stable across rebuilds, **TCC (Accessibility + Input Monitoring) permissions persist** — no re-granting after every `swift build`.

### Manual build (when not using sign.sh)
```bash
swift build                          # Debug
swift build -c release               # Release

cp .build/debug/Znote build/Znote.app/Contents/MacOS/Znote
cp Sources/Znote/Resources/Info.plist build/Znote.app/Contents/Info.plist
cp Sources/Znote/Resources/Znote.icns build/Znote.app/Contents/Resources/Znote.icns
codesign --force --deep --options runtime \
    --sign "Developer ID Application: naisierding aihemaiti (ZVZ4AP4H2T)" \
    --entitlements Sources/Znote/Resources/Znote.entitlements \
    build/Znote.app
```

## Release
```bash
./release.sh v0.4.0                    # Create tag → push → GitHub Actions builds & publishes
./release.sh v0.4.0 -m "First release" # With custom tag message
./release.sh --list                    # List all tags
./release.sh --delete v0.4.0           # Delete tag locally + remotely
```
Script validates version format (`vX.Y.Z`), checks for uncommitted changes, confirms before pushing. GitHub Actions (`.github/workflows/build.yml`) triggers on tag push, builds release, creates GitHub Release with Znote.zip.

## Distribution (local signed + notarized)
```bash
./package.sh             # Produces dist/Znote.zip (signed + notarized + stapled)
./dmg.sh                 # Produces dist/Znote.dmg (signed + notarized + stapled)
```
One-time setup (stores Apple ID app-specific password in Keychain):
```bash
xcrun notarytool store-credentials "Znote-notary" \
    --apple-id "nicetooo.a@gmail.com" \
    --team-id "ZVZ4AP4H2T"
```

## Key Architecture

- **Fully native Swift** — WhisperKit (CoreML) replaces previous Python mlx_whisper dependency
- **No extra apps** — one self-contained .app bundle
- **Logging**: Use `log()` function (writes to `/tmp/znote.log`), NOT `print()`
- **App name**: "Znote" everywhere — bundle name, menu, window titles
- **Bundle identifier**: `com.znote.app`

## Hotkeys (Right-side modifier keys only — defaults; user can rebind side+modifier in Settings)
| Gesture | Action |
|---------|--------|
| Right ⌘ hold (>0.3s) | Push-to-talk recording |
| Right ⌘ tap (<0.3s) | Toggle History window |
| Right ⌥ tap | Translate selection (has 0.3s delay for double-tap detection) |
| Right ⌥ double-tap | Screenshot to clipboard |

Key codes: Right ⌘ = keyCode 54, Right ⌥ = keyCode 61. Device flags: NX_DEVICERCMDKEYMASK = 0x10, NX_DEVICERALTKEYMASK = 0x40.

## Whisper Behavior
- **Engine**: WhisperKit (Swift + CoreML), models cached at `~/Library/Application Support/Znote/Models/`
- **Compute units**: large models → `cpuAndGPU`; smaller models → `cpuAndNeuralEngine` (ANE)
- **Speed flags**: `withoutTimestamps=true`, `wordTimestamps=false`, `temperatureFallbackCount=0`, `prewarm=true`
- **Language detection**: Do NOT force language unless exactly 1 language selected in Settings (after deduplication — zh-Hans and zh-Hant both map to "zh"). Multiple selected → auto-detect → verify with NLLanguageRecognizer → retry with forced language if mismatch.
- **Token cleanup**: Strip `<\|...\|>` tokens via regex; merge multi-line output into single line
- **Chinese simplified/traditional**: Separate options in Settings. Only simplified → `CFStringTransform("Hant-Hans")`. Only traditional → `CFStringTransform("Hans-Hant")`. Both → no conversion.
- **Silence/hallucination**: Audio level threshold (peak RMS) + minimum duration check + expanded hallucination phrase blacklist (incl. "thank"/"thanks" variants)

## Translation
- Show result in **floating overlay** (NOT paste in-place). User reads it or clicks Copy.
- Google Translate free endpoint. NLLanguageRecognizer for auto-detection.

## UI Style
- All overlays (recording, translation, history) use **dark floating panel** style: borderless NSPanel, dark background, rounded corners
- History panel: NOT native macOS window — matches overlay theme
- Recording overlay: waveform animation with `sqrt(rms) * 2.5` for dynamic range; two-layer shadow stack for uniform glow

## Model Management
- Dropdown for **browsing/managing** (NOT activating). Separate "Activate" button.
- WhisperKit downloads to `~/Library/Application Support/Znote/Models/models/argmaxinc/whisperkit-coreml/<variant>/`

## Known Constraints
- **Both permissions needed**: CGEventTap needs Input Monitoring (key events) AND Accessibility (simulating Cmd+C/V)
- **NSView `tag` conflict**: Cannot override `tag` with stored property in NSView subclass — use different name (e.g., `index`)
- **SMAppService**: Requires app in /Applications for Launch at Login
- **First launch after signing identity change**: TCC entries are tied to the signing identity. If you ever switch certs (e.g. revoke + recreate), all permissions need to be re-added once. Subsequent rebuilds keep TCC because the identity stays the same.
- **Entitlements XML must NOT contain comments** — AMFI parser rejects them and codesign fails

## GitHub
- **Repo**: `nicetooo/Znote` (SSH: `git@github.com:nicetooo/Znote.git`)
- **Actions**: `.github/workflows/build.yml` — triggers on `v*` tag push + manual dispatch
- **Permissions**: `contents: write` set on workflow so `softprops/action-gh-release` can publish

## Project Structure
```
Sources/Znote/
├── main.swift              # Entry, custom log(), NSApplication setup
├── AppDelegate.swift       # Menu bar, coordinates all services, screenshot
├── KeyMonitor.swift        # CGEventTap: Right ⌘/⌥ tap/hold/double-tap, flag-sync state machine
├── AudioRecorder.swift     # AVAudioEngine, mono mixdown, RMS level
├── WhisperService.swift    # WhisperKit, onModelReady callback, ANE/GPU compute selection
├── TranslationService.swift # NLLanguageRecognizer + Google Translate
├── SystemIntegration.swift # Simulate Cmd+C/V, clipboard save/restore
├── RecordingOverlay.swift  # Floating waveform animation panel (two-layer glow)
├── TranslationOverlay.swift # Loading dots → result + Copy button
├── HistoryStore.swift      # SQLite CRUD
├── HistoryWindow.swift     # Dark floating panel: search, date pills, expand rows
├── Settings.swift          # UserDefaults, hotkey customization types, model list
├── SettingsWindow.swift    # Hotkey pills, language select, model manage, Launch at Login
└── Resources/
    ├── Info.plist           # com.znote.app, LSUIElement=true
    ├── Znote.entitlements   # Hardened runtime entitlements (mic, WhisperKit relaxations)
    └── Znote.icns
```

Root-level scripts:
- `sign.sh` — build + refresh bundle + sign with stable Developer ID
- `package.sh` — produces signed + notarized + stapled `dist/Znote.zip`
- `dmg.sh` — produces signed + notarized + stapled `dist/Znote.dmg`
- `release.sh` — tag + push to trigger GitHub Actions release
- `install.sh` — legacy build-from-source installer (predates DMG distribution)
