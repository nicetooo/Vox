# Znote

macOS menu bar app for voice-to-text and instant translation. Runs entirely on-device using [WhisperKit](https://github.com/argmaxinc/WhisperKit) (pure Swift + CoreML) — no cloud APIs, no subscriptions, no Python, no external dependencies.

## What it does

| Shortcut | Action |
|----------|--------|
| **Hold Right ⌘** | Push-to-talk → transcribes speech → pastes text at cursor |
| **Tap Right ⌘** | Toggle history window |
| **Tap Right ⌥** | Translate selected text (Chinese ↔ English) |
| **Double-tap Right ⌥** | Screenshot selection → clipboard |

- **Voice input**: Hold the key, speak, release. Text is pasted wherever your cursor is.
- **Translation**: Select any text in any app, tap the key. A floating overlay shows the translation.
- **History**: All voice inputs and translations are saved locally (SQLite). Search, filter by date, copy, delete.
- **Screenshot**: Double-tap triggers macOS interactive screenshot tool, result goes to clipboard.

## Requirements

- Apple Silicon Mac (M1/M2/M3/M4)
- macOS 14 (Sonoma) or later
- That's it — no Python, no pip, no ffmpeg, no brew

## Install

**From release (recommended):**

Download `Znote.zip` or `Znote.dmg` from [Releases](https://github.com/nicetooo/Znote/releases), unzip / mount, drag `Znote.app` to `/Applications`.

**Build from source:**

```bash
git clone https://github.com/nicetooo/Znote.git
cd Znote
swift build -c release
mkdir -p build/Znote.app/Contents/{MacOS,Resources}
cp .build/release/Znote build/Znote.app/Contents/MacOS/
cp Sources/Znote/Resources/Info.plist build/Znote.app/Contents/
cp Sources/Znote/Resources/Znote.icns build/Znote.app/Contents/Resources/
codesign --force --sign - build/Znote.app
open build/Znote.app
```

## Permissions

Znote needs three macOS permissions (System Settings → Privacy & Security):

1. **Accessibility** — to simulate Cmd+C/V for clipboard operations
2. **Input Monitoring** — to detect Right ⌘ and Right ⌥ key events
3. **Microphone** — to record audio for voice input

The menu bar icon shows orange warnings if permissions are missing — click them to jump to the right settings page.

> Note: Releases are signed with a stable Developer ID Application certificate, so TCC permissions persist across upgrades. If you rebuild locally with ad-hoc signing, permissions reset on each rebuild — use `./sign.sh` to sign with the stable identity.

## Settings

Click the waveform icon in the menu bar → Settings:

- **Languages**: Select which languages you speak. If only one is selected, Whisper is forced to that language (best accuracy). With multiple, it auto-detects and verifies the result.
- **Whisper Model**: Download and switch between models. Default is `large-v3` (best quality). Models are stored in `~/Library/Application Support/Znote/Models/`.
- **Silence Filter**: Adjust microphone sensitivity and minimum recording duration to prevent Whisper hallucination on silent/short recordings.
- **Hotkeys**: Rebind each action to a side (left/right) + modifier (⌘/⌥/⌃). The gesture (hold / tap / double-tap) is fixed per action.

### Available models

| Model | Size | Notes |
|-------|------|-------|
| large-v3 | ~3 GB | Best quality (default) |
| large-v2 | ~3 GB | Previous best |
| distil-large-v3 | ~1.5 GB | Fast, English-focused (Chinese accuracy degraded) |
| medium | ~1.5 GB | Balanced |
| small | ~500 MB | Lightweight |
| base | ~150 MB | Minimal |
| tiny | ~80 MB | Fastest, lowest quality |

## How it works

- **Speech recognition**: Records audio via `AVAudioEngine`, transcribes with WhisperKit (CoreML, runs locally on Apple Silicon GPU/ANE). Model preloads at app startup for instant transcription. Merges multi-line output, optionally converts between simplified/traditional Chinese.
- **Language verification**: When multiple languages are selected, Whisper auto-detects. If the result language doesn't match your selected set, it automatically retries with a forced language.
- **Translation**: Uses `NLLanguageRecognizer` for language detection + Google Translate free endpoint. Result shown in a floating dark overlay with a copy button.
- **History**: SQLite database at `~/Library/Application Support/Znote/history.sqlite`. Search, date filtering (Today / 7 days / 30 days), expandable rows.
- **Hotkeys**: Global `CGEventTap` monitors modifier keys. State machine syncs from `event.flags` on every event to recover from `.tapDisabledByUserInput` drops.

## Project structure

```
Sources/
├── CSQLite/                    # C shim for system sqlite3
└── Znote/
    ├── main.swift              # App entry point, logging setup
    ├── AppDelegate.swift       # Menu bar, coordinates all services
    ├── KeyMonitor.swift        # CGEventTap hotkey detection (flag-sync state machine)
    ├── AudioRecorder.swift     # AVAudioEngine recording + audio levels
    ├── WhisperService.swift    # WhisperKit transcription + language verification
    ├── TranslationService.swift # NLLanguageRecognizer + Google Translate
    ├── SystemIntegration.swift # Cmd+C/V simulation, clipboard
    ├── RecordingOverlay.swift  # Floating waveform animation during recording
    ├── TranslationOverlay.swift # Floating panel with translation result
    ├── HistoryStore.swift      # SQLite CRUD operations
    ├── HistoryWindow.swift     # Dark floating history panel
    ├── Settings.swift          # UserDefaults, hotkey customization, model management
    └── SettingsWindow.swift    # Settings UI
```

## Troubleshooting

**"Failed to create event tap"** — Grant Input Monitoring permission and restart the app.

**Voice input produces no text** — Check the menu bar for orange permission warnings. Ensure the model is downloaded in Settings.

**First launch is slow** — CoreML compiles the model for your hardware on first use. This is a one-time process; subsequent launches load from cache.

**"Loading model..." when recording** — The model is still loading in the background. The overlay will switch to the waveform automatically once ready.

**Chinese text comes out as traditional** — In Settings, select "简体中文 (Simplified)" only (not both). The app will auto-convert output to simplified Chinese.

## License

MIT
