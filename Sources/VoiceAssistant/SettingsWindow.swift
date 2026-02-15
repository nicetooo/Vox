import AppKit

// MARK: - Settings Window Controller

class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var languageCheckboxes: [String: NSButton] = [:]
    private var hintLabel: NSTextField?
    private var modelPopup: NSPopUpButton?
    private var activateButton: NSButton?
    private var downloadButton: NSButton?
    private var deleteButton: NSButton?
    private var downloadStatus: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var silenceValueLabel: NSTextField?
    private var durationValueLabel: NSTextField?
    private var isDownloading = false

    func showSettings() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "VoiceAssistant Settings"
        w.delegate = self
        w.center()
        w.isReleasedWhenClosed = false
        w.contentView = buildContent()

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    // MARK: - Build Content

    private func buildContent() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 500))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
        ])

        // === Languages ===
        stack.addArrangedSubview(makeHeader("Recognition Languages"))
        stack.addArrangedSubview(makeLanguageGrid())

        let hint = makeNote("")
        self.hintLabel = hint
        stack.addArrangedSubview(hint)
        updateLanguageHint()

        stack.addArrangedSubview(makeSeparator())

        // === Whisper Model ===
        stack.addArrangedSubview(makeHeader("Whisper Model"))
        stack.addArrangedSubview(makeModelSection())

        stack.addArrangedSubview(makeSeparator())

        // === Audio Detection ===
        stack.addArrangedSubview(makeHeader("Silence Filter"))
        stack.addArrangedSubview(makeNote("Skip recordings that are too quiet or too short (prevents Whisper hallucination)."))

        let silenceRow = makeSliderRow(
            label: "Mic sensitivity:",
            value: Double(Settings.shared.silenceThreshold),
            min: 0.01, max: 0.30,
            labelLeft: "Sensitive",
            labelRight: "Strict",
            action: #selector(silenceChanged(_:))
        )
        stack.addArrangedSubview(silenceRow.row)
        self.silenceValueLabel = silenceRow.valueLabel

        let durationRow = makeSliderRow(
            label: "Min duration:",
            value: Settings.shared.minRecordingDuration,
            min: 0.2, max: 2.0,
            labelLeft: "0.2s",
            labelRight: "2.0s",
            action: #selector(durationChanged(_:))
        )
        stack.addArrangedSubview(durationRow.row)
        self.durationValueLabel = durationRow.valueLabel

        return container
    }

    // MARK: - Language Grid

    private func makeLanguageGrid() -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 4
        grid.columnSpacing = 12

        let languages = Settings.availableLanguages
        let selected = Set(Settings.shared.selectedLanguages)

        var row: [NSView] = []
        for (index, lang) in languages.enumerated() {
            let cb = NSButton(checkboxWithTitle: lang.name, target: self, action: #selector(languageToggled(_:)))
            cb.tag = index
            cb.state = selected.contains(lang.code) ? .on : .off
            cb.font = NSFont.systemFont(ofSize: 13)
            languageCheckboxes[lang.code] = cb
            row.append(cb)

            if row.count == 2 || index == languages.count - 1 {
                while row.count < 2 { row.append(NSView()) }
                grid.addRow(with: row)
                row = []
            }
        }

        return grid
    }

    // MARK: - Model Section (Dropdown + Download)

    private func makeModelSection() -> NSView {
        let vstack = NSStackView()
        vstack.orientation = .vertical
        vstack.alignment = .leading
        vstack.spacing = 8

        // Row 1: dropdown
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 390).isActive = true
        popup.target = self
        popup.action = #selector(modelSelected(_:))
        self.modelPopup = popup
        vstack.addArrangedSubview(popup)

        // Row 2: action buttons
        let hstack = NSStackView()
        hstack.orientation = .horizontal
        hstack.spacing = 8

        let actBtn = NSButton(title: "Activate", target: self, action: #selector(activateClicked))
        actBtn.bezelStyle = .rounded
        actBtn.font = NSFont.systemFont(ofSize: 12)
        self.activateButton = actBtn
        hstack.addArrangedSubview(actBtn)

        let dlBtn = NSButton(title: "Download", target: self, action: #selector(downloadClicked))
        dlBtn.bezelStyle = .rounded
        dlBtn.font = NSFont.systemFont(ofSize: 12)
        self.downloadButton = dlBtn
        hstack.addArrangedSubview(dlBtn)

        let delBtn = NSButton(title: "Delete", target: self, action: #selector(deleteClicked))
        delBtn.bezelStyle = .rounded
        delBtn.font = NSFont.systemFont(ofSize: 12)
        delBtn.contentTintColor = NSColor.systemRed
        self.deleteButton = delBtn
        hstack.addArrangedSubview(delBtn)

        vstack.addArrangedSubview(hstack)

        // Progress bar (hidden by default)
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1.0
        progress.doubleValue = 0
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 390).isActive = true
        self.progressBar = progress
        vstack.addArrangedSubview(progress)

        // Status label
        let status = makeNote("")
        self.downloadStatus = status
        vstack.addArrangedSubview(status)

        refreshModelList()
        return vstack
    }

    private func refreshModelList() {
        guard let popup = modelPopup else { return }

        // Remember what was selected before refresh (by representedObject)
        let previousSelection = popup.selectedItem?.representedObject as? String

        popup.removeAllItems()

        let cached = Settings.cachedModelNames()
        let activeModel = Settings.shared.whisperModel

        for model in Settings.popularModels {
            let downloaded = cached.contains(model.name)
            let isActive = (model.name == activeModel)
            let prefix: String
            if isActive {
                prefix = "▶ "      // active model
            } else if downloaded {
                prefix = "● "      // downloaded but not active
            } else {
                prefix = "   "     // not downloaded
            }
            let title = "\(prefix)\(model.displayName)  (\(model.size))"
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = model.name
        }

        // Add any cached models not in popular list
        let popularNames = Set(Settings.popularModels.map(\.name))
        let extraCached = cached.filter { !popularNames.contains($0) }.sorted()
        if !extraCached.isEmpty {
            popup.menu?.addItem(NSMenuItem.separator())
            for name in extraCached {
                let isActive = (name == activeModel)
                let prefix = isActive ? "▶ " : "● "
                popup.addItem(withTitle: "\(prefix)\(name)")
                popup.lastItem?.representedObject = name
            }
        }

        // Restore previous selection if it still exists, otherwise select active model
        let targetSelection = previousSelection ?? activeModel
        for i in 0..<popup.numberOfItems {
            if let obj = popup.item(at: i)?.representedObject as? String, obj == targetSelection {
                popup.selectItem(at: i)
                break
            }
        }

        updateModelButtons()
    }

    private func updateModelButtons() {
        guard let popup = modelPopup,
              let actBtn = activateButton,
              let dlBtn = downloadButton,
              let delBtn = deleteButton else { return }

        let cached = Settings.cachedModelNames()
        let activeModel = Settings.shared.whisperModel

        guard let selected = popup.selectedItem?.representedObject as? String else { return }

        let isDownloaded = cached.contains(selected)
        let isActive = (selected == activeModel)

        // Activate button: show for downloaded models that aren't active
        if isActive {
            actBtn.isHidden = false
            actBtn.isEnabled = false
            actBtn.title = "Active ✓"
        } else if isDownloaded {
            actBtn.isHidden = false
            actBtn.isEnabled = !isDownloading
            actBtn.title = "Activate"
        } else {
            actBtn.isHidden = true
        }

        // Download button: show only for non-downloaded models
        if isDownloaded {
            dlBtn.isHidden = true
        } else {
            dlBtn.isHidden = false
            dlBtn.isEnabled = !isDownloading
            dlBtn.title = isDownloading ? "Downloading..." : "Download"
        }

        // Delete button: show for any downloaded model
        delBtn.isHidden = !isDownloaded
        delBtn.isEnabled = isDownloaded && !isDownloading

        // Status text
        if isDownloading {
            // Don't overwrite download progress messages
        } else if !isDownloaded {
            downloadStatus?.stringValue = "Not downloaded — click Download to install."
        } else if isActive {
            let size = Settings.cachedModelSize(selected)
            downloadStatus?.stringValue = "▶ Active model (\(size) on disk)"
        } else {
            let size = Settings.cachedModelSize(selected)
            downloadStatus?.stringValue = "Downloaded (\(size) on disk) — click Activate to use."
        }
    }

    // MARK: - Actions

    @objc private func languageToggled(_ sender: NSButton) {
        var selected: [String] = []
        for lang in Settings.availableLanguages {
            if let cb = languageCheckboxes[lang.code], cb.state == .on {
                selected.append(lang.code)
            }
        }
        Settings.shared.selectedLanguages = selected
        updateLanguageHint()
        log("Settings: languages = \(selected)")
    }

    @objc private func modelSelected(_ sender: NSPopUpButton) {
        // Dropdown selection = browse/manage only. Does NOT change the active model.
        updateModelButtons()
    }

    @objc private func activateClicked() {
        guard let name = modelPopup?.selectedItem?.representedObject as? String else { return }
        let cached = Settings.cachedModelNames()
        guard cached.contains(name) else { return }

        Settings.shared.whisperModel = name
        log("Settings: activated model = \(name)")
        downloadStatus?.stringValue = "▶ Switched to \(name)"
        refreshModelList()
    }

    @objc private func downloadClicked() {
        guard let name = modelPopup?.selectedItem?.representedObject as? String else { return }
        guard !isDownloading else { return }

        isDownloading = true
        downloadButton?.isEnabled = false
        downloadButton?.title = "Downloading..."
        progressBar?.isHidden = false
        progressBar?.doubleValue = 0

        Settings.downloadModel(name, onProgress: { [weak self] progress in
            self?.downloadStatus?.stringValue = progress.message
            self?.progressBar?.doubleValue = progress.percent
        }, onComplete: { [weak self] success in
            self?.isDownloading = false
            self?.progressBar?.isHidden = true
            if success {
                self?.downloadStatus?.stringValue = "✓ Downloaded! Click Activate to use."
                log("Settings: model downloaded: \(name)")
            } else {
                self?.downloadStatus?.stringValue = "✗ Download failed."
            }
            self?.refreshModelList()
        })
    }

    @objc private func deleteClicked() {
        guard let name = modelPopup?.selectedItem?.representedObject as? String else { return }

        let size = Settings.cachedModelSize(name)

        // Confirm deletion
        let alert = NSAlert()
        alert.messageText = "Delete Model?"
        alert.informativeText = "Delete \(name) (\(size)) from disk? You can re-download it later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // If deleting the active model, switch to another one first
        if name == Settings.shared.whisperModel {
            let cached = Settings.cachedModelNames()
            let fallback = cached.first(where: { $0 != name }) ?? Settings.popularModels[0].name
            Settings.shared.whisperModel = fallback
            log("Settings: switched to \(fallback) before deleting \(name)")
        }

        if Settings.deleteModel(name) {
            downloadStatus?.stringValue = "✓ Deleted (freed \(size))"
        } else {
            downloadStatus?.stringValue = "✗ Failed to delete."
        }
        refreshModelList()
    }

    @objc private func silenceChanged(_ sender: NSSlider) {
        let value = Float(sender.doubleValue)
        Settings.shared.silenceThreshold = value
        silenceValueLabel?.stringValue = String(format: "%.2f", value)
    }

    @objc private func durationChanged(_ sender: NSSlider) {
        let value = sender.doubleValue
        Settings.shared.minRecordingDuration = value
        durationValueLabel?.stringValue = String(format: "%.1fs", value)
    }

    // MARK: - Hint

    private func updateLanguageHint() {
        let langs = Settings.shared.selectedLanguages
        switch langs.count {
        case 0:
            hintLabel?.stringValue = "No language selected — Whisper will auto-detect"
        case 1:
            let name = Settings.availableLanguages.first(where: { $0.code == langs[0] })?.name ?? langs[0]
            hintLabel?.stringValue = "→ \(name) — best accuracy for this language"
        default:
            hintLabel?.stringValue = "Multiple languages — Whisper will auto-detect"
        }
    }

    // MARK: - UI Helpers

    private func makeHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.boldSystemFont(ofSize: 13)
        return label
    }

    private func makeNote(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeSeparator() -> NSBox {
        let sep = NSBox()
        sep.boxType = .separator
        return sep
    }

    private func makeSliderRow(
        label: String, value: Double, min: Double, max: Double,
        labelLeft: String, labelRight: String, action: Selector
    ) -> (row: NSStackView, valueLabel: NSTextField) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6

        let lbl = NSTextField(labelWithString: label)
        lbl.font = NSFont.systemFont(ofSize: 13)
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.widthAnchor.constraint(equalToConstant: 110).isActive = true
        row.addArrangedSubview(lbl)

        let leftHint = NSTextField(labelWithString: labelLeft)
        leftHint.font = NSFont.systemFont(ofSize: 10)
        leftHint.textColor = .tertiaryLabelColor
        row.addArrangedSubview(leftHint)

        let slider = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: action)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        row.addArrangedSubview(slider)

        let rightHint = NSTextField(labelWithString: labelRight)
        rightHint.font = NSFont.systemFont(ofSize: 10)
        rightHint.textColor = .tertiaryLabelColor
        row.addArrangedSubview(rightHint)

        // Hidden value label (still used for programmatic updates)
        let valLabel = NSTextField(labelWithString: "")
        valLabel.isHidden = true
        row.addArrangedSubview(valLabel)

        return (row, valLabel)
    }
}
