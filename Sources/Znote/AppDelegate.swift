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
    private var recordingMode: RecordingMode = .transcribe
    private var regionSelector: RegionSelector!
    private var captureActionPicker: CaptureActionPicker!
    private var screenRecorder: ScreenRecorder?
    private var recordingStopButton: RecordingStopButton?
    private var recordingStartedAt: Date?

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
        menu.addItem(NSMenuItem(title: L("menu.history"), action: #selector(openHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("menu.settings"), action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        statusItem.menu = menu
    }

    private func hotkeyMenuLabel(for action: HotkeyAction) -> String {
        let b = Settings.shared.hotkeyBinding(for: action)
        // gesture.displayName already localized via Settings.swift
        return "\(b.gesture.displayName) \(b.side.displayName) \(b.modifier.symbol) — \(action.displayName)"
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
            issues.append((L("menu.permission.accessibility"), #selector(openAccessibilitySettings)))
        }
        if !inputMonitoringOK {
            issues.append((L("menu.permission.input_monitoring"), #selector(openInputMonitoringSettings)))
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
        regionSelector = RegionSelector()
        captureActionPicker = CaptureActionPicker()

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
            self.recordingOverlay.show(hint: self.recordingMode == .translate ? L("overlay.translate_hint") : nil)
        }
    }

    // MARK: - Key Monitor

    private func setupKeyMonitor() {
        keyMonitor = KeyMonitor()

        keyMonitor.onVoiceInputDown     = { [weak self] in self?.startRecording(mode: .transcribe) }
        keyMonitor.onVoiceInputUp       = { [weak self] in self?.stopRecordingAndProcess() }
        keyMonitor.onVoiceTranslateDown = { [weak self] in self?.startRecording(mode: .translate) }
        keyMonitor.onVoiceTranslateUp   = { [weak self] in self?.stopRecordingAndProcess() }
        keyMonitor.onToggleHistory      = { [weak self] in self?.toggleHistory() }
        keyMonitor.onTranslate          = { [weak self] in self?.translateSelection() }
        keyMonitor.onScreenshot         = { [weak self] in self?.takeScreenshot() }

        keyMonitor.start()
    }

    /// Called by Settings UI after the user changes hotkey bindings.
    func reloadHotkeyBindings() {
        keyMonitor?.reloadBindings()
    }

    // MARK: - Voice Input

    /// Two modes share the same recording pipeline; `mode` controls which
    /// Whisper task runs after the user releases the hotkey.
    private func startRecording(mode: RecordingMode) {
        guard !isRecording else { return }

        // Translate mode needs a model that supports task=translate.
        // Turbo (large-v3-v20240930) doesn't — OpenAI dropped translation
        // when they shrunk the decoder for speed. Fail fast with a clear
        // message instead of silently transcribing in the source language.
        if mode == .translate {
            let model = Settings.shared.whisperModel
            if !WhisperService.supportsTranslate(model) {
                log("startRecording: model '\(model)' doesn't support translate — aborting")
                DispatchQueue.main.async {
                    NSSound(named: "Frog")?.play()
                    self.recordingOverlay.showMessage(L("overlay.no_translate"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                        self?.recordingOverlay.hide()
                    }
                }
                return
            }
        }

        isRecording = true
        recordingMode = mode
        DispatchQueue.main.async {
            self.updateState(.recording)
            NSSound(named: "Tink")?.play()
            // If model not ready, show loading message; otherwise show waveform
            if self.whisperService.isLoading || !self.whisperService.isModelReady {
                log("Model not ready, showing loading message...")
                self.recordingOverlay.showMessage(L("overlay.loading_model"))
            } else {
                self.recordingOverlay.show(hint: mode == .translate ? L("overlay.translate_hint") : nil)
            }
            self.audioRecorder.startRecording()
            log("Recording (mode: \(mode))...")
        }
    }

    private func stopRecordingAndProcess() {
        guard isRecording else { return }
        let mode = recordingMode
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
            log("\(mode == .translate ? "Translating" : "Transcribing")...")

            let audioPath = self.audioRecorder.outputPath
            let whisper = self.whisperService!
            let integration = self.systemIntegration!

            // If model still not ready by the time recording ends, keep showing loading message
            if whisper.isLoading || !whisper.isModelReady {
                log("Model not ready yet, keeping loading message...")
                self.recordingOverlay.showMessage(L("overlay.loading_model"))
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

                let text = await whisper.transcribe(audioPath: audioPath, translate: mode == .translate)
                await MainActor.run {
                    self.recordingOverlay.hide()
                    if let text = text, !text.isEmpty {
                        log("Result: \(text)")
                        integration.pasteText(text)
                        // Both modes write to the voice history. The translated
                        // English text is just another voice transcript from
                        // the user's perspective.
                        HistoryStore.shared.addVoice(text: text)
                    } else {
                        log("No speech detected.")
                    }
                    self.updateState(.ready)
                }
            }
        }
    }

    // MARK: - Screen Capture (region → screenshot or record)

    /// Returns the directory where screenshots are saved, creating it if necessary.
    private func screenshotsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Znote").appendingPathComponent("Screenshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Triggered by Right ⌥ double-tap. Flow:
    ///   1. Show RegionSelector — user drags out a rectangle.
    ///   2. On selection, show CaptureActionPicker near the rect.
    ///   3. User picks Capture (screenshot) or Record (video, Phase 2).
    private func takeScreenshot() {
        DispatchQueue.main.async {
            self.regionSelector.begin(
                onSelected: { [weak self] rect in
                    self?.handleRegionSelected(rect)
                },
                onCancel: {
                    log("Capture cancelled at region select")
                }
            )
        }
    }

    private func handleRegionSelected(_ rect: NSRect) {
        captureActionPicker.show(
            near: rect,
            onCapture: { [weak self] in
                self?.captureScreenshot(rect: rect)
            },
            onRecord: { [weak self] in
                self?.startScreenRecording(rect: rect)
            },
            onCancel: {
                log("Capture cancelled at action picker")
            }
        )
    }

    /// Take a PNG screenshot of `rect` (NSScreen / window coords, bottom-left origin).
    /// Uses `screencapture -R x,y,w,h` which expects top-left origin in primary-display
    /// pixel coords, so we convert.
    private func captureScreenshot(rect: NSRect) {
        let timestamp = DateFormatter.screenshotTimestamp.string(from: Date())
        let filename = "screenshot-\(timestamp).png"
        let fileURL = screenshotsDirectory().appendingPathComponent(filename)

        // NSScreen.frame uses bottom-left origin in a unified coordinate space.
        // screencapture -R uses top-left origin where (0,0) is the PRIMARY display's
        // top-left. `NSScreen.screens.first` is not guaranteed to be primary —
        // the actual primary always has frame.origin == .zero in the NSScreen
        // coordinate system. Use that as the reference height.
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        let cgRect = CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )

        // Give the AppKit compositor a frame or two to actually remove the
        // CaptureActionPicker panel before launching screencapture — orderOut
        // returns synchronously but the window may still be in the framebuffer
        // for ~16ms. Without this we sometimes catch a faint picker outline at
        // the edge of the screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            DispatchQueue.global(qos: .userInitiated).async {
                log("captureScreenshot: NSRect=\(rect) → screencapture rect=\(cgRect) → \(fileURL.path)")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                let rArg = "\(Int(cgRect.origin.x.rounded())),\(Int(cgRect.origin.y.rounded())),\(Int(cgRect.width.rounded())),\(Int(cgRect.height.rounded()))"
                process.arguments = ["-R", rArg, "-o", "-x", fileURL.path]
                // -R: rect; -o: no shadow; -x: don't play camera shutter sound
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    log("Screenshot failed to launch: \(error)")
                    return
                }

                guard FileManager.default.fileExists(atPath: fileURL.path),
                      let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
                    log("Screenshot empty/missing — skipping.")
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }

                DispatchQueue.main.async {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    if let image = NSImage(data: data) {
                        pb.writeObjects([image])
                    } else {
                        pb.setData(data, forType: .png)
                    }
                    log("Screenshot copied to clipboard (\(data.count) bytes)")
                    HistoryStore.shared.addScreenshot(path: fileURL.path)
                }
            }
        }
    }

    /// Returns the directory where screen recordings are saved.
    private func recordingsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Znote").appendingPathComponent("Recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Start a screen recording bounded to `rect` (NSScreen / window coords).
    /// Shows a floating stop control; user clicks it (or presses ESC) to finish.
    /// The first time the user records, macOS will prompt for Screen Recording
    /// permission — start() throws and we surface the system dialog requirement.
    private func startScreenRecording(rect: NSRect) {
        // If already recording, do nothing — the user must stop the current
        // one via the floating button first.
        if screenRecorder != nil {
            log("startScreenRecording: already recording, ignoring")
            return
        }

        let timestamp = DateFormatter.screenshotTimestamp.string(from: Date())
        let output = recordingsDirectory().appendingPathComponent("recording-\(timestamp).mov")

        let recorder = ScreenRecorder()
        self.screenRecorder = recorder
        self.recordingStartedAt = Date()

        Task { [weak self] in
            do {
                try await recorder.start(region: rect, output: output)
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    // Show floating stop control.
                    let btn = RecordingStopButton()
                    btn.show { [weak self] in self?.stopScreenRecording() }
                    self.recordingStopButton = btn
                    log("Recording started → \(output.path)")
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.screenRecorder = nil
                    self.recordingStartedAt = nil
                    log("startScreenRecording failed: \(error.localizedDescription)")

                    let alert = NSAlert()
                    alert.messageText = L("recording.error.title")
                    let msg = error.localizedDescription
                    if msg.lowercased().contains("permission") || msg.lowercased().contains("declined") {
                        alert.informativeText = L("recording.error.permission")
                    } else {
                        alert.informativeText = msg
                    }
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: L("button.open_system_settings"))
                    alert.addButton(withTitle: L("button.cancel"))
                    if alert.runModal() == .alertFirstButtonReturn {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }

    private func stopScreenRecording() {
        guard let recorder = screenRecorder else { return }
        let started = recordingStartedAt
        let stopBtn = recordingStopButton
        self.recordingStopButton = nil  // hide control immediately to avoid double-click
        stopBtn?.hide()

        Task { [weak self] in
            let url = await recorder.stop()
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.screenRecorder = nil
                self.recordingStartedAt = nil

                if let url = url {
                    let duration = started.map { Date().timeIntervalSince($0) }
                    HistoryStore.shared.addRecording(path: url.path, duration: duration)
                    log("Recording saved \(url.path), duration=\(duration ?? 0)s")
                } else {
                    log("Recording stop returned nil URL — write may have failed")
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

// MARK: - Recording Mode

/// What to do with the audio captured during a push-to-talk hold.
///   - `.transcribe` (Right ⌘ hold): output original-language text.
///   - `.translate`  (Right ⌥ hold): use Whisper's built-in any-language →
///     English task, output English text.
enum RecordingMode: String {
    case transcribe
    case translate
}

// MARK: - Helpers

private extension DateFormatter {
    /// Filesystem-safe timestamp used in screenshot filenames: `20260517-143022`.
    static let screenshotTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
