# Vox

macOS menu bar app for voice-to-text and instant translation. Runs entirely on-device using [MLX Whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) — no cloud APIs, no subscriptions.

## What it does

| Shortcut | Action |
|----------|--------|
| **Hold Right ⌘** | Push-to-talk → transcribes speech → pastes text at cursor |
| **Tap Right ⌘** | Toggle history window |
| **Tap Right ⌥** | Translate selected text (Chinese ↔ English) |
| **Double-tap Right ⌥** | Screenshot selection → clipboard |

- **Voice input**: Hold the key, speak, release. Text is pasted wherever your cursor is.
- **Translation**: Select any text in any app, tap the key. A floating overlay shows the translation near your cursor.
- **History**: All voice inputs and translations are saved locally (SQLite). Search, filter by date, copy, delete.
- **Screenshot**: Double-tap triggers macOS interactive screenshot tool, result goes to clipboard.

## Requirements

- Apple Silicon Mac (M1/M2/M3/M4) — MLX does not support Intel
- macOS 14 (Sonoma) or later
- Python 3.9+ with `mlx-whisper` and `huggingface_hub` packages
- ~1.6 GB disk space for the default Whisper model

## Install

**One-liner:**

```bash
git clone https://github.com/nicetooo/Vox.git && cd Vox && ./install.sh
```

The install script handles everything: checks your environment, installs Python dependencies, builds from source, copies to `/Applications/Vox.app`.

**Manual build:**

```bash
git clone https://github.com/nicetooo/Vox.git
cd Vox
pip install mlx-whisper huggingface_hub
swift build
# Create .app bundle
mkdir -p build/Vox.app/Contents/{MacOS,Resources}
cp .build/debug/Vox build/Vox.app/Contents/MacOS/
cp Sources/Vox/Resources/Info.plist build/Vox.app/Contents/
cp Sources/Vox/Resources/Vox.icns build/Vox.app/Contents/Resources/
codesign --force --deep --sign - build/Vox.app
open build/Vox.app
```

## Permissions

Vox needs three macOS permissions (System Settings → Privacy & Security):

1. **Accessibility** — to simulate Cmd+C/V for clipboard operations
2. **Input Monitoring** — to detect Right ⌘ and Right ⌥ key events
3. **Microphone** — to record audio for voice input

> Note: Every rebuild produces a new binary with a different code signature. You'll need to re-grant Accessibility and Input Monitoring permissions after each rebuild.

## Settings

Click the waveform icon in the menu bar → Settings:

- **Languages**: Select which languages you speak. If only one is selected, Whisper is forced to that language (best accuracy). With multiple, it auto-detects and verifies the result.
- **Whisper Model**: Download and switch between models. Default is `large-v3-turbo` (1.6 GB, good balance of speed and accuracy).
- **Silence Filter**: Adjust microphone sensitivity and minimum recording duration to prevent Whisper hallucination on silent/short recordings.

## How it works

- **Speech recognition**: Records audio via `AVAudioEngine`, transcribes with `mlx_whisper` CLI (runs locally on Apple Silicon GPU via MLX). Merges multi-line output, optionally converts between simplified/traditional Chinese.
- **Language verification**: When multiple languages are selected, Whisper auto-detects. If the result language doesn't match your selected set (e.g., Whisper outputs Korean but you only selected Chinese + English), it automatically retries with a forced language.
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
    ├── WhisperService.swift    # mlx_whisper subprocess + language verification
    ├── TranslationService.swift # NLLanguageRecognizer + Google Translate
    ├── SystemIntegration.swift # Cmd+C/V simulation, clipboard
    ├── RecordingOverlay.swift  # Floating waveform animation during recording
    ├── TranslationOverlay.swift # Floating panel with translation result
    ├── HistoryStore.swift      # SQLite CRUD operations
    ├── HistoryWindow.swift     # Dark floating history panel
    ├── Settings.swift          # UserDefaults, model management, Python discovery
    └── SettingsWindow.swift    # Settings UI
```

## Troubleshooting

**"Failed to create event tap"** — Grant Input Monitoring permission and restart the app.

**Voice input produces no text** — Check that `mlx_whisper` is installed (`which mlx_whisper`). The app auto-discovers it from common Python install locations.

**First transcription is slow** — The Whisper model needs to be downloaded on first use. Open Settings → Whisper Model → Download. Subsequent runs use the cached model.

**Chinese text comes out as traditional** — In Settings, select "简体中文 (Simplified)" only (not both). The app will auto-convert Whisper's output to simplified Chinese.

## License

MIT
