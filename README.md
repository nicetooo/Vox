# Vox

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

Download `Vox.app.zip` from [Releases](https://github.com/nicetooo/Vox/releases), unzip, drag to `/Applications`.

**Build from source:**

```bash
git clone https://github.com/nicetooo/Vox.git
cd Vox
swift build -c release
mkdir -p build/Vox.app/Contents/{MacOS,Resources}
cp .build/release/Vox build/Vox.app/Contents/MacOS/
cp Sources/Vox/Resources/Info.plist build/Vox.app/Contents/
cp Sources/Vox/Resources/Vox.icns build/Vox.app/Contents/Resources/
codesign --force --sign - build/Vox.app
open build/Vox.app
```

## Permissions

Vox needs three macOS permissions (System Settings → Privacy & Security):

1. **Accessibility** — to simulate Cmd+C/V for clipboard operations
2. **Input Monitoring** — to detect Right ⌘ and Right ⌥ key events
3. **Microphone** — to record audio for voice input

The menu bar icon shows orange warnings if permissions are missing — click them to jump to the right settings page.

> Note: Every rebuild produces a new binary with a different code signature. You'll need to toggle Accessibility and Input Monitoring permissions off/on after each rebuild.

## Settings

Click the waveform icon in the menu bar → Settings:

- **Languages**: Select which languages you speak. If only one is selected, Whisper is forced to that language (best accuracy). With multiple, it auto-detects and verifies the result.
- **Whisper Model**: Download and switch between models. Default is `large-v3` (best quality). Models are stored in `~/Library/Application Support/Vox/Models/`.
- **Silence Filter**: Adjust microphone sensitivity and minimum recording duration to prevent Whisper hallucination on silent/short recordings.

### Available models

| Model | Size | Notes |
|-------|------|-------|
| large-v3 | ~3 GB | Best quality (default) |
| large-v2 | ~3 GB | Previous best |
| distil-large-v3 | ~1.5 GB | Fast + good quality |
| medium | ~1.5 GB | Balanced |
| small | ~500 MB | Lightweight |
| base | ~150 MB | Minimal |
| tiny | ~80 MB | Fastest, lowest quality |

## How it works

- **Speech recognition**: Records audio via `AVAudioEngine`, transcribes with WhisperKit (CoreML, runs locally on Apple Silicon GPU). Model preloads at app startup for instant transcription. Merges multi-line output, optionally converts between simplified/traditional Chinese.
- **Language verification**: When multiple languages are selected, Whisper auto-detects. If the result language doesn't match your selected set, it automatically retries with a forced language.
- **Translation**: Uses `NLLanguageRecognizer` for language detection + Google Translate free endpoint. Result shown in a floating dark overlay with a copy button.
- **History**: SQLite database at `~/Library/Application Support/Vox/history.sqlite`. Search, date filtering (Today / 7 days / 30 days), expandable rows.
- **Hotkeys**: Global `CGEventTap` monitors Right ⌘ and Right ⌥. No modifier key conflicts since these specific right-side keys are rarely used.

## Project structure

```
Sources/
├── CSQLite/                    # C shim for system sqlite3
└── Vox/
    ├── main.swift              # App entry point, logging setup
    ├── AppDelegate.swift       # Menu bar, coordinates all services
    ├── KeyMonitor.swift        # CGEventTap hotkey detection
    ├── AudioRecorder.swift     # AVAudioEngine recording + audio levels
    ├── WhisperService.swift    # WhisperKit transcription + language verification
    ├── TranslationService.swift # NLLanguageRecognizer + Google Translate
    ├── SystemIntegration.swift # Cmd+C/V simulation, clipboard
    ├── RecordingOverlay.swift  # Floating waveform animation during recording
    ├── TranslationOverlay.swift # Floating panel with translation result
    ├── HistoryStore.swift      # SQLite CRUD operations
    ├── HistoryWindow.swift     # Dark floating history panel
    ├── Settings.swift          # UserDefaults, WhisperKit model management
    └── SettingsWindow.swift    # Settings UI
```

## Troubleshooting

**"Failed to create event tap"** — Grant Input Monitoring permission and restart the app.

**Voice input produces no text** — Check the menu bar for orange permission warnings. Ensure the model is downloaded in Settings.

**First launch is slow** — CoreML compiles the model for your hardware on first use. This is a one-time process; subsequent launches load from cache.

**"Loading model..." when recording** — The model is still loading in the background. Wait a moment and try again.

**Chinese text comes out as traditional** — In Settings, select "简体中文 (Simplified)" only (not both). The app will auto-convert output to simplified Chinese.

## License

MIT
