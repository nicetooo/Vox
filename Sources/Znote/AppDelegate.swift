import AppKit
import ApplicationServices

// macOS IOKit API for Input Monitoring permission check
// 0 = kIOHIDRequestTypeListenEvent
// Returns: 0 = granted, 1 = denied
@_silgen_name("IOHIDCheckAccess")
private func IOHIDCheckAccess(_ requestType: Int32) -> Int32

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
        preloadModel()
    }

    // MARK: - Model Preload

    private func preloadModel() {
        let model = Settings.shared.whisperModel
        log("Preloading model '\(model)' at startup...")
        let whisper = self.whisperService!
        Task.detached {
            let success = await whisper.loadModel(model)
            await MainActor.run {
                if success {
                    log("Model '\(model)' ready.")
                } else {
                    log("Failed to preload model '\(model)'.")
                }
            }
        }
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

    // Tag IDs for dynamic permission menu items
    private let permissionSectionTag = 9000

    // Tag IDs for dynamic hotkey-description menu items
    private let hotkeySectionTag = 9100

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateState(.ready)

        let menu = NSMenu()
        menu.delegate = self
        // Hotkey descriptions are populated dynamically in menuWillOpen.
        menu.addItem(NSMenuItem(title: "History...", action: #selector(openHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Znote", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        statusItem.menu = menu
    }

    private func hotkeyMenuLabel(for action: HotkeyAction) -> String {
        let b = Settings.shared.hotkeyBinding(for: action)
        let prefix: String
        switch b.gesture {
        case .tap: prefix = "Tap"
        case .hold: prefix = "Hold"
        case .doubleTap: prefix = "Double-tap"
        }
        return "\(prefix) \(b.side.displayName) \(b.modifier.symbol) — \(action.displayName)"
    }

    // MARK: - Dynamic Menu (permission status)

    func menuWillOpen(_ menu: NSMenu) {
        // Remove old permission + hotkey items (we rebuild them each open).
        while let item = menu.items.first(where: {
            $0.tag == permissionSectionTag || $0.tag == hotkeySectionTag
        }) {
            menu.removeItem(item)
        }

        // Insert hotkey descriptions at the top (reflects current bindings).
        var insertIdx = 0
        for action in HotkeyAction.allCases {
            let item = NSMenuItem(title: hotkeyMenuLabel(for: action), action: nil, keyEquivalent: "")
            item.tag = hotkeySectionTag
            menu.insertItem(item, at: insertIdx)
            insertIdx += 1
        }
        let sepHot = NSMenuItem.separator()
        sepHot.tag = hotkeySectionTag
        menu.insertItem(sepHot, at: insertIdx)
        insertIdx += 1

        // Check permissions reliably
        let accessibilityOK = AXIsProcessTrusted()
        let inputMonitoringOK = IOHIDCheckAccess(0) == 0  // 0 = granted

        var issues: [(String, Selector)] = []

        if !accessibilityOK {
            issues.append(("⚠ 需要辅助功能权限 — 点击打开设置", #selector(openAccessibilitySettings)))
        }
        if !inputMonitoringOK {
            issues.append(("⚠ 需要输入监控权限 — 点击打开设置", #selector(openInputMonitoringSettings)))
        }

        if !issues.isEmpty {
            for (title, action) in issues {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.tag = permissionSectionTag
                let attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: NSColor.systemOrange,
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium)
                ]
                item.attributedTitle = NSAttributedString(string: title, attributes: attrs)
                menu.insertItem(item, at: insertIdx)
                insertIdx += 1
            }
            let sep = NSMenuItem.separator()
            sep.tag = permissionSectionTag
            menu.insertItem(sep, at: insertIdx)
        }
    }

    @objc private func openAccessibilitySettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openInputMonitoringSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func openSystemSettings(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
            log("Opened System Settings: \(urlString)")
        }
    }

    enum State { case ready, recording, processing }

    func updateState(_ state: State) {
        guard let button = statusItem?.button else { return }
        switch state {
        case .ready:
            button.image = makeWaveIcon(heights: [6, 12, 9], alpha: 1.0)
        case .recording:
            button.image = makeWaveIcon(heights: [10, 16, 13], alpha: 1.0)
        case .processing:
            button.image = makeWaveIcon(heights: [6, 12, 9], alpha: 0.5)
        }
    }

    /// Draw a custom waveform icon with 3 rounded bars of different heights.
    /// Returns a template image that adapts to light/dark menu bar.
    private func makeWaveIcon(heights: [CGFloat], alpha: CGFloat) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let barWidth: CGFloat = 3.0
            let spacing: CGFloat = 2.5
            let barCount = CGFloat(heights.count)
            let totalWidth = barCount * barWidth + (barCount - 1) * spacing
            let startX = (rect.width - totalWidth) / 2
            let centerY = rect.height / 2

            NSColor.black.withAlphaComponent(alpha).setFill()

            for (i, height) in heights.enumerated() {
                let x = startX + CGFloat(i) * (barWidth + spacing)
                let y = centerY - height / 2
                let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
                let path = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func openHistory() {
        historyController.showHistory()
    }

    private func toggleHistory() {
        log("Right ⌘ tap → toggle History")
        historyController.toggleHistory()
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

        // When the model finishes loading while the user is already recording,
        // swap the overlay from "Loading model..." to the live waveform.
        whisperService.onModelReady = { [weak self] in
            guard let self = self, self.isRecording else { return }
            log("Model became ready during recording — switching overlay to waveform")
            self.recordingOverlay.show()
        }
    }

    // MARK: - Key Monitor

    private func setupKeyMonitor() {
        keyMonitor = KeyMonitor()

        keyMonitor.onVoiceInputDown = { [weak self] in self?.startRecording() }
        keyMonitor.onVoiceInputUp = { [weak self] in self?.stopRecordingAndTranscribe() }
        keyMonitor.onToggleHistory = { [weak self] in self?.toggleHistory() }
        keyMonitor.onTranslate = { [weak self] in self?.translateSelection() }
        keyMonitor.onScreenshot = { [weak self] in self?.takeScreenshot() }

        keyMonitor.start()
    }

    /// Called by Settings UI after the user changes hotkey bindings.
    func reloadHotkeyBindings() {
        keyMonitor?.reloadBindings()
    }

    // MARK: - Voice Input

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        DispatchQueue.main.async {
            self.updateState(.recording)
            NSSound(named: "Tink")?.play()
            // If model not ready, show loading message; otherwise show waveform
            if self.whisperService.isLoading || !self.whisperService.isModelReady {
                log("Model not ready, showing loading message...")
                self.recordingOverlay.showMessage("Loading model...")
            } else {
                self.recordingOverlay.show()
            }
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

            let audioPath = self.audioRecorder.outputPath
            let whisper = self.whisperService!
            let integration = self.systemIntegration!

            // If model still not ready by the time recording ends, keep showing loading message
            if whisper.isLoading || !whisper.isModelReady {
                log("Model not ready yet, keeping loading message...")
                self.recordingOverlay.showMessage("Loading model...")
            }

            Task.detached {
                // Wait for model to be ready (if preloading is still in progress)
                while whisper.isLoading {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                }
                // If model still not ready after preload, try loading now
                if !whisper.isModelReady {
                    let model = Settings.shared.whisperModel
                    log("Model not loaded, loading '\(model)' now...")
                    _ = await whisper.loadModel(model)
                }

                let text = await whisper.transcribe(audioPath: audioPath)
                await MainActor.run {
                    self.recordingOverlay.hide()
                    if let text = text, !text.isEmpty {
                        log("Result: \(text)")
                        integration.pasteText(text)
                        HistoryStore.shared.addVoice(text: text)
                    } else {
                        log("No speech detected.")
                    }
                    self.updateState(.ready)
                }
            }
        }
    }

    // MARK: - Screenshot

    private func takeScreenshot() {
        DispatchQueue.main.async {
            log("Taking screenshot to clipboard...")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-ic"]  // interactive selection → clipboard
            do {
                try process.run()
            } catch {
                log("Screenshot failed: \(error)")
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
