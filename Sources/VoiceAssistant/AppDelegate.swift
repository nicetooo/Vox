import AppKit
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var keyMonitor: KeyMonitor!
    private var audioRecorder: AudioRecorder!
    private var whisperService: WhisperService!
    private var translationService: TranslationService!
    private var systemIntegration: SystemIntegration!
    private var recordingOverlay: RecordingOverlay!
    private var translationOverlay: TranslationOverlay!
    private var settingsController: SettingsWindowController!
    private var historyController: HistoryWindowController!
    private var isRecording = false

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("applicationDidFinishLaunching")
        checkAccessibility()
        setupMenuBar()
        log("Menu bar setup done")
        setupServices()
        log("Services ready")
        setupKeyMonitor()
        log("Ready. Hold Right ⌘ to record, tap Right ⌥ to translate.")
    }

    // MARK: - Accessibility Check

    private func checkAccessibility() {
        let trusted = AXIsProcessTrusted()
        log("Accessibility trusted: \(trusted)")
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            log("WARNING: Accessibility not granted. Hotkeys and paste won't work.")
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateState(.ready)

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Hold Right ⌘ — Voice Input", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Tap Right ⌥ — Translate Selection", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "History...", action: #selector(openHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceAssistant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    enum State { case ready, recording, processing }

    func updateState(_ state: State) {
        guard let button = statusItem?.button else { return }
        switch state {
        case .ready:
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Ready")
        case .recording:
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")
        case .processing:
            button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Processing")
        }
    }

    @objc private func openHistory() {
        historyController.showHistory()
    }

    @objc private func openSettings() {
        settingsController.showSettings()
    }

    // MARK: - Services

    private func setupServices() {
        audioRecorder = AudioRecorder()
        whisperService = WhisperService()
        translationService = TranslationService()
        systemIntegration = SystemIntegration()
        recordingOverlay = RecordingOverlay()
        translationOverlay = TranslationOverlay()
        settingsController = SettingsWindowController()
        historyController = HistoryWindowController()

        // Initialize history store
        _ = HistoryStore.shared

        // Connect audio level to overlay
        audioRecorder.onAudioLevel = { [weak self] level in
            DispatchQueue.main.async {
                self?.recordingOverlay.updateLevel(level)
            }
        }
    }

    // MARK: - Key Monitor

    private func setupKeyMonitor() {
        keyMonitor = KeyMonitor()

        keyMonitor.onRightCmdDown = { [weak self] in
            self?.startRecording()
        }
        keyMonitor.onRightCmdUp = { [weak self] in
            self?.stopRecordingAndTranscribe()
        }
        keyMonitor.onRightOptTap = { [weak self] in
            self?.translateSelection()
        }

        keyMonitor.start()
    }

    // MARK: - Voice Input

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        DispatchQueue.main.async {
            self.updateState(.recording)
            NSSound(named: "Tink")?.play()
            self.recordingOverlay.show()
            self.audioRecorder.startRecording()
            log("Recording...")
        }
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }
        isRecording = false
        DispatchQueue.main.async {
            self.audioRecorder.stopRecording()
            self.recordingOverlay.hide()

            // Check if recording had meaningful audio before wasting time on Whisper
            guard self.audioRecorder.hasMeaningfulAudio else {
                log("Skipped transcription: too short or too quiet")
                NSSound(named: "Frog")?.play()
                self.updateState(.ready)
                return
            }

            NSSound(named: "Pop")?.play()
            self.updateState(.processing)
            log("Transcribing...")

            DispatchQueue.global(qos: .userInitiated).async {
                let text = self.whisperService.transcribe(audioPath: self.audioRecorder.outputPath)
                DispatchQueue.main.async {
                    if let text = text, !text.isEmpty {
                        log("Result: \(text)")
                        self.systemIntegration.pasteText(text)
                        HistoryStore.shared.addVoice(text: text)
                    } else {
                        log("No speech detected.")
                    }
                    self.updateState(.ready)
                }
            }
        }
    }

    // MARK: - Translation

    private func translateSelection() {
        DispatchQueue.main.async {
            // If overlay is already showing, dismiss it (toggle behavior)
            if self.translationOverlay.isShowing {
                self.translationOverlay.hide()
                return
            }

            log("Translating selection...")

            // Copy selected text
            guard let selectedText = self.systemIntegration.getSelectedText() else {
                log("No text selected.")
                return
            }

            log("Selected: \(selectedText)")

            // Show loading overlay immediately for instant feedback
            self.translationOverlay.showLoading()
            self.updateState(.processing)

            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.translationService.translateWithInfo(selectedText)
                DispatchQueue.main.async {
                    if let result = result {
                        log("Translation: \(result.text)")
                        self.translationOverlay.showResult(result.text)
                        HistoryStore.shared.addTranslation(
                            input: selectedText, output: result.text,
                            sourceLang: result.sourceLang, targetLang: result.targetLang
                        )
                    } else {
                        log("Translation failed.")
                        self.translationOverlay.hide()
                    }
                    self.updateState(.ready)
                }
            }
        }
    }
}
