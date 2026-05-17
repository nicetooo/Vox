import AppKit
import ServiceManagement

// MARK: - Settings Panel (borderless, can become key)

private class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Dark Toggle (language checkbox replacement)

private class DarkToggle: NSView {
    private var title: String
    private(set) var isOn: Bool
    var index: Int = 0
    var onToggle: ((DarkToggle) -> Void)?

    init(title: String, isOn: Bool = false) {
        self.title = title
        self.isOn = isOn
        super.init(frame: .zero)
        wantsLayer = true
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setOn(_ on: Bool) {
        isOn = on
        updateAppearance()
        needsDisplay = true
    }

    private func updateAppearance() {
        layer?.cornerRadius = 8
        layer?.backgroundColor = isOn
            ? NSColor(white: 0.22, alpha: 1.0).cgColor
            : NSColor(white: 0.14, alpha: 1.0).cgColor
        layer?.borderWidth = isOn ? 1.0 : 0.5
        layer?.borderColor = isOn
            ? NSColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 0.6).cgColor
            : NSColor(white: 0.25, alpha: 1.0).cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 0.28, alpha: 1.0).cgColor
    }
    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            isOn.toggle()
            updateAppearance()
            needsDisplay = true  // draw(_:) renders checkmark/title — must trigger redraw
            onToggle?(self)
        } else {
            updateAppearance()
            needsDisplay = true  // restore checkmark/title after drag-away
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Checkmark
        let checkColor: NSColor = isOn
            ? NSColor(red: 0.35, green: 0.82, blue: 0.45, alpha: 1.0)
            : NSColor(white: 0.30, alpha: 1.0)
        let checkAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: checkColor,
            .font: NSFont.systemFont(ofSize: 12, weight: .bold)
        ]
        let check = isOn ? "✓" : "○"
        check.draw(at: NSPoint(x: 10, y: (bounds.height - 16) / 2), withAttributes: checkAttrs)

        // Title
        let titleColor: NSColor = isOn ? .white : NSColor(white: 0.60, alpha: 1.0)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: titleColor,
            .font: NSFont.systemFont(ofSize: 12.5, weight: isOn ? .medium : .regular)
        ]
        title.draw(at: NSPoint(x: 28, y: (bounds.height - 16) / 2), withAttributes: titleAttrs)
    }
}

// MARK: - Dark Action Button

private class SettingsActionButton: NSView {
    private var title: String
    private let style: Style
    var isEnabled: Bool = true { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    enum Style { case normal, accent, destructive }

    init(title: String, style: Style = .normal) {
        self.title = title
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        updateBg()
    }
    required init?(coder: NSCoder) { fatalError() }

    func updateTitle(_ t: String) { title = t; needsDisplay = true }

    private func bgColor() -> NSColor {
        switch style {
        case .normal: return NSColor(white: 0.20, alpha: 1.0)
        case .accent: return NSColor(red: 0.20, green: 0.45, blue: 0.85, alpha: 1.0)
        case .destructive: return NSColor(white: 0.20, alpha: 1.0)
        }
    }
    private func updateBg() {
        layer?.cornerRadius = 8
        layer?.backgroundColor = bgColor().cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        layer?.backgroundColor = NSColor(white: 0.32, alpha: 1.0).cgColor
    }
    override func mouseUp(with event: NSEvent) {
        updateBg()
        guard isEnabled else { return }
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color: NSColor
        if !isEnabled {
            color = NSColor(white: 0.35, alpha: 1.0)
        } else {
            switch style {
            case .normal: color = .white
            case .accent: color = .white
            case .destructive: color = NSColor(red: 1.0, green: 0.42, blue: 0.42, alpha: 1.0)
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        let s = title.size(withAttributes: attrs)
        title.draw(at: NSPoint(x: (bounds.width - s.width) / 2,
                               y: (bounds.height - s.height) / 2), withAttributes: attrs)
    }
}

// MARK: - Segmented Pill (dark themed multi-choice selector)

private class SegmentedPill: NSView {
    private let options: [String]
    private(set) var selectedIndex: Int
    var onChange: ((Int) -> Void)?

    init(options: [String], selectedIndex: Int) {
        self.options = options
        self.selectedIndex = selectedIndex
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(white: 0.14, alpha: 1.0).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 0.22, alpha: 1.0).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSelectedIndex(_ idx: Int) {
        guard idx != selectedIndex, idx >= 0, idx < options.count else { return }
        selectedIndex = idx
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        guard bounds.contains(loc) else { return }
        let segW = bounds.width / CGFloat(options.count)
        let idx = min(max(Int(loc.x / segW), 0), options.count - 1)
        if idx != selectedIndex {
            selectedIndex = idx
            needsDisplay = true
            onChange?(idx)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let segW = bounds.width / CGFloat(options.count)
        let selRect = NSRect(
            x: CGFloat(selectedIndex) * segW + 2, y: 2,
            width: segW - 4, height: bounds.height - 4
        )
        NSColor(red: 0.20, green: 0.45, blue: 0.85, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: selRect, xRadius: 6, yRadius: 6).fill()

        for (i, opt) in options.enumerated() {
            let isSelected = (i == selectedIndex)
            let color: NSColor = isSelected ? .white : NSColor(white: 0.60, alpha: 1.0)
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .medium : .regular)
            ]
            let size = opt.size(withAttributes: attrs)
            let x = CGFloat(i) * segW + (segW - size.width) / 2
            let y = (bounds.height - size.height) / 2
            opt.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }
    }
}

// MARK: - Dark Model Row (replaces NSPopUpButton)

private class ModelRow: NSView {
    let modelName: String
    let displayName: String
    let sizeText: String
    let noteText: String
    var isDownloaded: Bool = false
    var isActive: Bool = false
    var isSelected: Bool = false
    var onClick: ((ModelRow) -> Void)?

    init(modelName: String, displayName: String, sizeText: String, noteText: String) {
        self.modelName = modelName
        self.displayName = displayName
        self.sizeText = sizeText
        self.noteText = noteText
        super.init(frame: .zero)
        wantsLayer = true
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }

    func updateAppearance() {
        layer?.cornerRadius = 8
        if isSelected {
            layer?.backgroundColor = NSColor(white: 0.22, alpha: 1.0).cgColor
            layer?.borderWidth = 1.0
            layer?.borderColor = NSColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 0.5).cgColor
        } else {
            layer?.backgroundColor = NSColor(white: 0.14, alpha: 1.0).cgColor
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor(white: 0.22, alpha: 1.0).cgColor
        }
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 0.26, alpha: 1.0).cgColor
    }
    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) { onClick?(self) }
        updateAppearance()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Two-line layout: name + size on top row, note on bottom row.
        let topY: CGFloat = bounds.height - 22  // baseline for top row
        let botY: CGFloat = 8                   // baseline for bottom row

        // Status indicator (aligned with name row)
        let statusColor: NSColor
        let statusText: String
        if isActive {
            statusColor = NSColor(red: 0.35, green: 0.82, blue: 0.45, alpha: 1.0)
            statusText = "▶"
        } else if isDownloaded {
            statusColor = NSColor(white: 0.50, alpha: 1.0)
            statusText = "●"
        } else {
            statusColor = NSColor(white: 0.28, alpha: 1.0)
            statusText = "○"
        }
        let statusAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: statusColor,
            .font: NSFont.systemFont(ofSize: 10)
        ]
        statusText.draw(at: NSPoint(x: 12, y: topY + 3), withAttributes: statusAttrs)

        // Model name
        let nameColor: NSColor = isActive ? .white : NSColor(white: 0.85, alpha: 1.0)
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: nameColor,
            .font: NSFont.systemFont(ofSize: 13, weight: isActive ? .semibold : .medium)
        ]
        displayName.draw(at: NSPoint(x: 30, y: topY), withAttributes: nameAttrs)

        // Size on the right of top row
        let sizeAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.45, alpha: 1.0),
            .font: NSFont.systemFont(ofSize: 11)
        ]
        let sizeSize = sizeText.size(withAttributes: sizeAttrs)
        sizeText.draw(at: NSPoint(x: bounds.width - sizeSize.width - 12, y: topY + 1),
                      withAttributes: sizeAttrs)

        // Bottom row: pros/cons note (single line, light grey)
        if !noteText.isEmpty {
            let noteAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor(white: 0.50, alpha: 1.0),
                .font: NSFont.systemFont(ofSize: 11)
            ]
            noteText.draw(at: NSPoint(x: 30, y: botY), withAttributes: noteAttrs)
        }
    }
}

// MARK: - Settings Window Controller

class SettingsWindowController: NSObject, NSWindowDelegate {
    private var panel: SettingsPanel?
    private var languageToggles: [String: DarkToggle] = [:]
    private var hintLabel: NSTextField?
    private var modelRows: [ModelRow] = []
    private var selectedModelName: String?
    private var activateButton: SettingsActionButton?
    private var downloadButton: SettingsActionButton?
    private var deleteButton: SettingsActionButton?
    private var downloadStatus: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var silenceSlider: NSSlider?
    private var durationSlider: NSSlider?
    private var silenceValueLabel: NSTextField?
    private var durationValueLabel: NSTextField?
    private var loginToggle: DarkToggle?
    private var localKeyMonitor: Any?
    private var isDownloading = false
    private var hotkeyPills: [HotkeyAction: (side: SegmentedPill, modifier: SegmentedPill, gesture: SegmentedPill?)] = [:]
    private var hotkeyConflictLabel: NSTextField?

    func showSettings() {
        if let p = panel {
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w: CGFloat = 520, h: CGFloat = 640

        let p = SettingsPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.contentView = buildContent(w, h)
        p.center()

        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = p
        setupKeyMonitor()
    }

    func windowWillClose(_ n: Notification) {
        removeKeyMonitor()
        panel = nil
    }

    // MARK: - ESC to close

    private func setupKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.panel?.orderOut(nil)
                self?.panel = nil
                self?.removeKeyMonitor()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
    }

    // MARK: - Build Content

    private func buildContent(_ width: CGFloat, _ height: CGFloat) -> NSView {
        let pad: CGFloat = 20

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.96).cgColor
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true

        // --- Title bar ---
        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = .white
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)

        let hint = NSTextField(labelWithString: "ESC to close")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor(white: 0.35, alpha: 1.0)
        hint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hint)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            hint.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
        ])

        // --- Scroll view for content ---
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay

        let contentWidth = width - pad * 2
        let content = buildScrollContent(contentWidth)
        let flip = FlippedView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: content.frame.height))
        flip.addSubview(content)
        scroll.documentView = flip

        root.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
        ])

        return root
    }

    private func buildScrollContent(_ width: CGFloat) -> NSView {
        var y: CGFloat = 0

        // FlippedView so y=0 is at the TOP and increasing y goes DOWN — matches
        // the natural reading order of the section-by-section layout below.
        // Without this, the FIRST section gets rendered at the BOTTOM of the
        // scroll view (and the last single language item ends up alone at top).
        let container = FlippedView()

        // === Languages ===
        y += addSectionHeader("Recognition Languages", at: y, in: container, width: width)
        y += 6
        y += addLanguageGrid(at: y, in: container, width: width)
        y += 4
        let hintLbl = makeSubLabel("")
        hintLbl.frame = NSRect(x: 0, y: y, width: width, height: 16)
        container.addSubview(hintLbl)
        self.hintLabel = hintLbl
        updateLanguageHint()
        y += 22

        y += addSeparator(at: y, in: container, width: width)

        // === Whisper Model ===
        y += addSectionHeader("Whisper Model", at: y, in: container, width: width)
        y += 6
        y += addModelList(at: y, in: container, width: width)
        y += 8
        y += addModelButtons(at: y, in: container, width: width)
        y += 6

        // Progress bar
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: y, width: width, height: 4))
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1.0
        progress.isHidden = true
        self.progressBar = progress
        container.addSubview(progress)
        y += 8

        let statusLbl = makeSubLabel("")
        statusLbl.frame = NSRect(x: 0, y: y, width: width, height: 16)
        container.addSubview(statusLbl)
        self.downloadStatus = statusLbl
        y += 22

        y += addSeparator(at: y, in: container, width: width)

        // === Silence Filter ===
        y += addSectionHeader("Silence Filter", at: y, in: container, width: width)
        let filterHint = makeSubLabel("Skip recordings that are too quiet or too short.")
        filterHint.frame = NSRect(x: 0, y: y, width: width, height: 16)
        container.addSubview(filterHint)
        y += 22

        y += addSlider(
            label: "Mic sensitivity", value: Double(Settings.shared.silenceThreshold),
            min: 0.01, max: 0.30, leftHint: "Sensitive", rightHint: "Strict",
            at: y, in: container, width: width, isSilence: true
        )
        y += 6
        y += addSlider(
            label: "Min duration", value: Settings.shared.minRecordingDuration,
            min: 0.2, max: 2.0, leftHint: "0.2s", rightHint: "2.0s",
            at: y, in: container, width: width, isSilence: false
        )

        y += addSeparator(at: y, in: container, width: width)

        // === Hotkeys ===
        y += addSectionHeader("Hotkeys", at: y, in: container, width: width)
        let hkHint = makeSubLabel("Gesture is fixed per action — change Side/Modifier below.")
        hkHint.frame = NSRect(x: 0, y: y, width: width, height: 16)
        container.addSubview(hkHint)
        y += 22
        y += addHotkeyRows(at: y, in: container, width: width)
        y += 8

        let resetBtn = SettingsActionButton(title: "Reset to defaults", style: .normal)
        resetBtn.frame = NSRect(x: 0, y: y, width: 140, height: 28)
        resetBtn.onClick = { [weak self] in self?.resetHotkeysClicked() }
        container.addSubview(resetBtn)
        y += 34

        let conflictLbl = NSTextField(labelWithString: "")
        conflictLbl.font = .systemFont(ofSize: 11, weight: .medium)
        conflictLbl.textColor = NSColor(red: 1.0, green: 0.55, blue: 0.25, alpha: 1.0)
        conflictLbl.frame = NSRect(x: 0, y: y, width: width, height: 16)
        container.addSubview(conflictLbl)
        self.hotkeyConflictLabel = conflictLbl
        updateHotkeyConflictLabel()
        y += 22

        y += addSeparator(at: y, in: container, width: width)

        // === General ===
        y += addSectionHeader("General", at: y, in: container, width: width)
        y += 6
        let login = DarkToggle(title: "Launch at Login", isOn: SMAppService.mainApp.status == .enabled)
        login.frame = NSRect(x: 0, y: y, width: width, height: 32)
        login.onToggle = { [weak self] toggle in self?.loginToggled(toggle) }
        container.addSubview(login)
        self.loginToggle = login
        y += 36
        let loginHint = makeSubLabel("Start Znote automatically when you log in.")
        loginHint.frame = NSRect(x: 0, y: y, width: width, height: 16)
        container.addSubview(loginHint)
        y += 26

        container.frame = NSRect(x: 0, y: 0, width: width, height: y)

        refreshModelList()
        updateModelButtons()
        return container
    }

    // MARK: - Section Builders

    private func addSectionHeader(_ text: String, at y: CGFloat, in container: NSView, width: CGFloat) -> CGFloat {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor(white: 0.70, alpha: 1.0)
        label.frame = NSRect(x: 0, y: y, width: width, height: 18)
        container.addSubview(label)
        return 24
    }

    private func addSeparator(at y: CGFloat, in container: NSView, width: CGFloat) -> CGFloat {
        let sep = NSView(frame: NSRect(x: 0, y: y + 8, width: width, height: 0.5))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 0.20, alpha: 1.0).cgColor
        container.addSubview(sep)
        return 20
    }

    private func addLanguageGrid(at y: CGFloat, in container: NSView, width: CGFloat) -> CGFloat {
        let languages = Settings.availableLanguages
        let selected = Set(Settings.shared.selectedLanguages)
        let cols = 2
        let spacing: CGFloat = 6
        let itemHeight: CGFloat = 32
        let itemWidth = (width - spacing) / CGFloat(cols)

        languageToggles = [:]
        var totalHeight: CGFloat = 0

        for (index, lang) in languages.enumerated() {
            let col = index % cols
            let row = index / cols
            let x = CGFloat(col) * (itemWidth + spacing)
            let iy = y + CGFloat(row) * (itemHeight + spacing)

            let toggle = DarkToggle(title: lang.name, isOn: selected.contains(lang.code))
            toggle.index = index
            toggle.frame = NSRect(x: x, y: iy, width: itemWidth, height: itemHeight)
            toggle.onToggle = { [weak self] _ in self?.languageToggled() }
            container.addSubview(toggle)
            languageToggles[lang.code] = toggle

            totalHeight = CGFloat(row + 1) * (itemHeight + spacing)
        }
        return totalHeight
    }

    private func addModelList(at y: CGFloat, in container: NSView, width: CGFloat) -> CGFloat {
        let rowHeight: CGFloat = 52  // two-line layout: name + note
        let spacing: CGFloat = 4
        modelRows = []

        for (index, model) in Settings.popularModels.enumerated() {
            let row = ModelRow(
                modelName: model.name,
                displayName: model.displayName,
                sizeText: model.size,
                noteText: model.note
            )
            row.frame = NSRect(x: 0, y: y + CGFloat(index) * (rowHeight + spacing), width: width, height: rowHeight)
            row.onClick = { [weak self] r in self?.modelRowClicked(r) }
            container.addSubview(row)
            modelRows.append(row)
        }
        return CGFloat(Settings.popularModels.count) * (rowHeight + spacing)
    }

    private func addModelButtons(at y: CGFloat, in container: NSView, width: CGFloat) -> CGFloat {
        let btnHeight: CGFloat = 30
        let btnSpacing: CGFloat = 8
        var x: CGFloat = 0

        let actBtn = SettingsActionButton(title: "Activate", style: .accent)
        actBtn.frame = NSRect(x: x, y: y, width: 80, height: btnHeight)
        actBtn.onClick = { [weak self] in self?.activateClicked() }
        container.addSubview(actBtn)
        self.activateButton = actBtn
        x += 80 + btnSpacing

        let dlBtn = SettingsActionButton(title: "Download", style: .normal)
        dlBtn.frame = NSRect(x: x, y: y, width: 90, height: btnHeight)
        dlBtn.onClick = { [weak self] in self?.downloadClicked() }
        container.addSubview(dlBtn)
        self.downloadButton = dlBtn
        x += 90 + btnSpacing

        let delBtn = SettingsActionButton(title: "Delete", style: .destructive)
        delBtn.frame = NSRect(x: x, y: y, width: 70, height: btnHeight)
        delBtn.onClick = { [weak self] in self?.deleteClicked() }
        container.addSubview(delBtn)
        self.deleteButton = delBtn

        return btnHeight + 4
    }

    private func addSlider(label: String, value: Double, min: Double, max: Double,
                           leftHint: String, rightHint: String,
                           at y: CGFloat, in container: NSView, width: CGFloat, isSilence: Bool) -> CGFloat {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 12, weight: .medium)
        labelField.textColor = NSColor(white: 0.70, alpha: 1.0)
        labelField.frame = NSRect(x: 0, y: y, width: 110, height: 18)
        container.addSubview(labelField)

        let sliderX: CGFloat = 112
        let sliderW = width - sliderX - 50
        let slider = NSSlider(value: value, minValue: min, maxValue: max,
                              target: self, action: isSilence ? #selector(silenceChanged(_:)) : #selector(durationChanged(_:)))
        slider.frame = NSRect(x: sliderX, y: y, width: sliderW, height: 18)
        slider.appearance = NSAppearance(named: .darkAqua)
        container.addSubview(slider)

        let valLabel = NSTextField(labelWithString: isSilence ? String(format: "%.2f", value) : String(format: "%.1fs", value))
        valLabel.font = .systemFont(ofSize: 11)
        valLabel.textColor = NSColor(white: 0.50, alpha: 1.0)
        valLabel.alignment = .right
        valLabel.frame = NSRect(x: width - 44, y: y, width: 44, height: 18)
        container.addSubview(valLabel)

        if isSilence {
            self.silenceSlider = slider
            self.silenceValueLabel = valLabel
        } else {
            self.durationSlider = slider
            self.durationValueLabel = valLabel
        }

        return 28
    }

    // MARK: - Hotkeys

    private func addHotkeyRows(at y: CGFloat, in container: NSView, width: CGFloat) -> CGFloat {
        let rowH: CGFloat = 34
        let spacing: CGFloat = 6
        // Panel is 520, contentWidth = 480. Distribute to give each pill comfortable padding.
        let labelW: CGFloat = 145    // "Translate Selection" at 12.5pt medium
        let sidePillW: CGFloat = 90  // Left / Right — each segment ~45px, "Right" text ~30px → 15px pad
        let modPillW: CGFloat = 80   // 3 symbols ⌘/⌥/⌃ — each ~27px
        let gestureGap: CGFloat = 10
        let gesturePillW: CGFloat = width - labelW - sidePillW - modPillW - (gestureGap * 3)
        // → 480 - 145 - 90 - 80 - 30 = 135 (each gesture segment ~67px, "Double" text ~40px → 27px pad)
        hotkeyPills = [:]

        for (i, action) in HotkeyAction.allCases.enumerated() {
            let rowY = y + CGFloat(i) * (rowH + spacing)
            let binding = Settings.shared.hotkeyBinding(for: action)

            let label = NSTextField(labelWithString: action.displayName)
            label.font = .systemFont(ofSize: 12.5, weight: .medium)
            label.textColor = NSColor(white: 0.82, alpha: 1.0)
            label.frame = NSRect(x: 0, y: rowY + (rowH - 18) / 2, width: labelW, height: 18)
            container.addSubview(label)

            let sideOpts = HotkeySide.allCases.map { $0.displayName }
            let sideIdx = HotkeySide.allCases.firstIndex(of: binding.side) ?? 0
            let sidePill = SegmentedPill(options: sideOpts, selectedIndex: sideIdx)
            sidePill.frame = NSRect(x: labelW + 10, y: rowY, width: sidePillW, height: rowH)
            sidePill.onChange = { [weak self] idx in
                var b = Settings.shared.hotkeyBinding(for: action)
                b.side = HotkeySide.allCases[idx]
                Settings.shared.setHotkeyBinding(b, for: action)
                self?.hotkeyBindingChanged()
            }
            container.addSubview(sidePill)

            let modOpts = HotkeyModifier.allCases.map { $0.symbol }
            let modIdx = HotkeyModifier.allCases.firstIndex(of: binding.modifier) ?? 0
            let modPill = SegmentedPill(options: modOpts, selectedIndex: modIdx)
            modPill.frame = NSRect(x: labelW + sidePillW + 20, y: rowY, width: modPillW, height: rowH)
            modPill.onChange = { [weak self] idx in
                var b = Settings.shared.hotkeyBinding(for: action)
                b.modifier = HotkeyModifier.allCases[idx]
                Settings.shared.setHotkeyBinding(b, for: action)
                self?.hotkeyBindingChanged()
            }
            container.addSubview(modPill)

            // Gesture: a SegmentedPill if 2+ options, otherwise a static label showing the locked gesture.
            let gestureX = labelW + sidePillW + modPillW + (gestureGap * 3)
            var gesturePill: SegmentedPill? = nil
            if action.allowedGestures.count > 1 {
                // Use shortened labels so they fit narrow pills.
                let gOpts = action.allowedGestures.map { g -> String in
                    switch g {
                    case .tap: return "Tap"
                    case .hold: return "Hold"
                    case .doubleTap: return "Double"
                    }
                }
                let gIdx = action.allowedGestures.firstIndex(of: binding.gesture) ?? 0
                let gPill = SegmentedPill(options: gOpts, selectedIndex: gIdx)
                gPill.frame = NSRect(x: gestureX, y: rowY, width: gesturePillW, height: rowH)
                gPill.onChange = { [weak self] idx in
                    var b = Settings.shared.hotkeyBinding(for: action)
                    b.gesture = action.allowedGestures[idx]
                    Settings.shared.setHotkeyBinding(b, for: action)
                    self?.hotkeyBindingChanged()
                }
                container.addSubview(gPill)
                gesturePill = gPill
            } else {
                let lockedLabel = NSTextField(labelWithString: binding.gesture.displayName)
                lockedLabel.font = .systemFont(ofSize: 12, weight: .medium)
                lockedLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
                lockedLabel.alignment = .center
                lockedLabel.frame = NSRect(x: gestureX, y: rowY + (rowH - 16) / 2, width: gesturePillW, height: 16)
                container.addSubview(lockedLabel)
            }

            hotkeyPills[action] = (sidePill, modPill, gesturePill)
        }

        return CGFloat(HotkeyAction.allCases.count) * (rowH + spacing)
    }

    private func hotkeyBindingChanged() {
        (NSApp.delegate as? AppDelegate)?.reloadHotkeyBindings()
        updateHotkeyConflictLabel()
    }

    private func updateHotkeyConflictLabel() {
        let conflicts = Settings.shared.hotkeyConflicts()
        if conflicts.isEmpty {
            hotkeyConflictLabel?.stringValue = ""
        } else {
            let parts = conflicts.map { "\($0.0.displayName) ↔ \($0.1.displayName)" }
            hotkeyConflictLabel?.stringValue = "⚠ Conflict: \(parts.joined(separator: ", "))"
        }
    }

    private func resetHotkeysClicked() {
        Settings.shared.resetHotkeys()
        for (action, pills) in hotkeyPills {
            let b = Settings.shared.hotkeyBinding(for: action)
            pills.side.setSelectedIndex(HotkeySide.allCases.firstIndex(of: b.side) ?? 0)
            pills.modifier.setSelectedIndex(HotkeyModifier.allCases.firstIndex(of: b.modifier) ?? 0)
            if let gPill = pills.gesture,
               let gIdx = action.allowedGestures.firstIndex(of: b.gesture) {
                gPill.setSelectedIndex(gIdx)
            }
        }
        hotkeyBindingChanged()
    }

    // MARK: - Model Management

    private func modelRowClicked(_ row: ModelRow) {
        selectedModelName = row.modelName
        for r in modelRows {
            r.isSelected = (r.modelName == row.modelName)
            r.updateAppearance()
        }
        updateModelButtons()
    }

    private func refreshModelList() {
        let cached = Settings.cachedModelNames()
        let activeModel = Settings.shared.whisperModel

        for row in modelRows {
            row.isDownloaded = cached.contains(row.modelName)
            row.isActive = (row.modelName == activeModel)
            row.isSelected = (row.modelName == (selectedModelName ?? activeModel))
            row.updateAppearance()
        }
        if selectedModelName == nil {
            selectedModelName = activeModel
        }
    }

    private func updateModelButtons() {
        guard let selected = selectedModelName else { return }
        let cached = Settings.cachedModelNames()
        let activeModel = Settings.shared.whisperModel
        let isDownloaded = cached.contains(selected)
        let isActive = (selected == activeModel)

        // Activate
        if isActive {
            activateButton?.updateTitle("Active ✓")
            activateButton?.isEnabled = false
        } else if isDownloaded {
            activateButton?.updateTitle("Activate")
            activateButton?.isEnabled = !isDownloading
        } else {
            activateButton?.updateTitle("Activate")
            activateButton?.isEnabled = false
        }

        // Download
        if isDownloaded {
            downloadButton?.updateTitle("Downloaded")
            downloadButton?.isEnabled = false
        } else {
            downloadButton?.updateTitle(isDownloading ? "Downloading..." : "Download")
            downloadButton?.isEnabled = !isDownloading
        }

        // Delete
        deleteButton?.isEnabled = isDownloaded && !isDownloading

        // Status
        if !isDownloading {
            if !isDownloaded {
                downloadStatus?.stringValue = "Not downloaded"
            } else if isActive {
                let size = Settings.cachedModelSize(selected)
                downloadStatus?.stringValue = "▶ Active model (\(size))"
            } else {
                let size = Settings.cachedModelSize(selected)
                downloadStatus?.stringValue = "Downloaded (\(size))"
            }
        }
    }

    // MARK: - Actions

    private func languageToggled() {
        var selected: [String] = []
        for lang in Settings.availableLanguages {
            if let toggle = languageToggles[lang.code], toggle.isOn {
                selected.append(lang.code)
            }
        }
        Settings.shared.selectedLanguages = selected
        updateLanguageHint()
        log("Settings: languages = \(selected)")
    }

    private func activateClicked() {
        guard let name = selectedModelName else { return }
        let cached = Settings.cachedModelNames()
        guard cached.contains(name) else { return }

        Settings.shared.whisperModel = name
        log("Settings: activated model = \(name)")
        downloadStatus?.stringValue = "▶ Switched to \(name)"
        refreshModelList()
        updateModelButtons()
    }

    private func downloadClicked() {
        guard let name = selectedModelName else { return }
        guard !isDownloading else { return }

        isDownloading = true
        downloadButton?.updateTitle("Downloading...")
        downloadButton?.isEnabled = false
        progressBar?.isHidden = false
        progressBar?.doubleValue = 0

        Settings.downloadModel(name, onProgress: { [weak self] progress in
            self?.downloadStatus?.stringValue = progress.message
            self?.progressBar?.doubleValue = progress.percent
        }, onComplete: { [weak self] success in
            self?.isDownloading = false
            self?.progressBar?.isHidden = true
            if success {
                self?.downloadStatus?.stringValue = "✓ Downloaded"
                log("Settings: model downloaded: \(name)")
            } else {
                self?.downloadStatus?.stringValue = "✗ Download failed"
            }
            self?.refreshModelList()
            self?.updateModelButtons()
        })
    }

    private func deleteClicked() {
        guard let name = selectedModelName else { return }
        let size = Settings.cachedModelSize(name)

        let alert = NSAlert()
        alert.messageText = "Delete Model?"
        alert.informativeText = "Delete \(name) (\(size))? You can re-download it later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if name == Settings.shared.whisperModel {
            let cached = Settings.cachedModelNames()
            let fallback = cached.first(where: { $0 != name }) ?? Settings.popularModels[0].name
            Settings.shared.whisperModel = fallback
        }

        if Settings.deleteModel(name) {
            downloadStatus?.stringValue = "✓ Deleted (\(size) freed)"
        } else {
            downloadStatus?.stringValue = "✗ Failed to delete"
        }
        refreshModelList()
        updateModelButtons()
    }

    private func loginToggled(_ toggle: DarkToggle) {
        do {
            if toggle.isOn {
                try SMAppService.mainApp.register()
                log("Settings: Launch at Login enabled")
            } else {
                try SMAppService.mainApp.unregister()
                log("Settings: Launch at Login disabled")
            }
        } catch {
            log("Settings: Launch at Login failed: \(error)")
            toggle.setOn(SMAppService.mainApp.status == .enabled)
        }
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
            hintLabel?.stringValue = "→ \(name) — best accuracy"
        default:
            hintLabel?.stringValue = "Multiple languages — Whisper will auto-detect"
        }
    }

    // MARK: - Helpers

    private func makeSubLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = NSColor(white: 0.40, alpha: 1.0)
        return label
    }
}

// MARK: - Flipped View (top-to-bottom layout for scroll view)

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
